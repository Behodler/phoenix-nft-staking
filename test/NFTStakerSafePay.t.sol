// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Covers audit finding M-01: `_safePay` must revert on a reward-token
///         shortfall rather than silently cap the payout and advance
///         `user.rewardDebt` past what was actually paid. Exercises the
///         revert on each of the three payout paths (claim / stake-restake /
///         unstake), pins the happy-path to a full-payment outcome, and
///         confirms `emergencyWithdraw` is still the escape hatch when the
///         reward budget is short.
contract NFTStakerSafePayTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal rate;

    event Claimed(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);

        // Under M-03 sizing R = totalStaked * latestPrice * A /
        // SECONDS_PER_YEAR. Pin a "single-staker rate" by pre-staking 10
        // units from a seed actor; tests then read `rate` post-stake when
        // they are the only additional participant or compute a share-
        // weighted expected accrual themselves.
        address seedStaker = address(0xCAFE);
        nft.mint(seedStaker, ID, 10);
        vm.prank(seedStaker);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(seedStaker);
        staker.stake(10);
        rate = staker.rewardRate();
        assertGt(rate, 0);
    }

    // -------------------------------------------------------------------
    // Phase 1 — shortfall reverts
    // -------------------------------------------------------------------

    function test_claim_revertsWhenBalanceBelowPending() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertEq(pending, rate * 50);

        (uint256 amtBefore, uint256 debtBefore) = staker.users(alice);

        uint256 shortBalance = pending - 1;
        deal(address(phUSD), address(staker), shortBalance);
        assertLt(phUSD.balanceOf(address(staker)), pending);

        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient reward balance"));
        staker.claim();

        (uint256 amtAfter, uint256 debtAfter) = staker.users(alice);
        assertEq(amtAfter, amtBefore);
        assertEq(debtAfter, debtBefore);
        assertEq(phUSD.balanceOf(alice), 0);
    }

    function test_stake_revertsWhenBalanceBelowPendingOnRestake() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        deal(address(phUSD), address(staker), pending - 1);

        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient reward balance"));
        staker.stake(5);
    }

    function test_unstake_revertsWhenBalanceBelowPending() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        deal(address(phUSD), address(staker), pending - 1);

        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient reward balance"));
        staker.unstake(5);
    }

    // -------------------------------------------------------------------
    // Phase 1 — happy path is unchanged
    // -------------------------------------------------------------------

    function test_safePay_happyPathUnchanged() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 10);
        uint256 pendingClaim = staker.pendingReward(alice);
        assertEq(pendingClaim, rate * 10);
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice), pendingClaim);
        assertEq(staker.pendingReward(alice), 0);
        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(debt, (amt * staker.accRewardPerShare()) / staker.ACC_PRECISION());

        vm.warp(block.timestamp + 10);
        uint256 pendingStake = staker.pendingReward(alice);
        assertGt(pendingStake, 0);
        uint256 aliceBalBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.stake(5);
        assertEq(phUSD.balanceOf(alice) - aliceBalBefore, pendingStake);
        (amt, debt) = staker.users(alice);
        assertEq(amt, 15);
        assertEq(debt, (amt * staker.accRewardPerShare()) / staker.ACC_PRECISION());

        vm.warp(block.timestamp + 10);
        uint256 pendingUnstake = staker.pendingReward(alice);
        assertGt(pendingUnstake, 0);
        aliceBalBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.unstake(15);
        assertEq(phUSD.balanceOf(alice) - aliceBalBefore, pendingUnstake);
        (amt, debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    // -------------------------------------------------------------------
    // Phase 1 — emergency escape hatch
    // -------------------------------------------------------------------

    function test_emergencyWithdraw_stillWorksWhenBudgetShort() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        deal(address(phUSD), address(staker), pending - 1);

        vm.prank(alice);
        try staker.claim() {
            fail();
        } catch {}

        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 nftBefore = nft.balanceOf(alice, ID);
        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(phUSD.balanceOf(alice), phusdBefore);
        assertEq(nft.balanceOf(alice, ID) - nftBefore, 10);
        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    // -------------------------------------------------------------------
    // Phase 3 — claim advances rewardDebt even when pending is zero
    // -------------------------------------------------------------------

    function test_claim_advancesRewardDebtEvenWhenPendingIsZero() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 25);

        vm.prank(alice);
        staker.claim();
        (uint256 amt1, uint256 debt1) = staker.users(alice);
        uint256 expected1 = (amt1 * staker.accRewardPerShare()) / staker.ACC_PRECISION();
        assertEq(debt1, expected1);

        assertEq(staker.pendingReward(alice), 0);
        vm.prank(alice);
        staker.claim();

        (uint256 amt2, uint256 debt2) = staker.users(alice);
        uint256 expected2 = (amt2 * staker.accRewardPerShare()) / staker.ACC_PRECISION();
        assertEq(debt2, expected2);
    }
}
