// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Covers audit finding M-01: `_safePay` must revert on a reward-token
///         shortfall rather than silently cap the payout and advance
///         `user.rewardDebt` past what was actually paid. Exercises the
///         revert on each of the three payout paths (claim / stake-restake /
///         unstake) and pins the happy-path to a full-payment outcome. Also
///         pins `emergencyWithdraw` as the escape hatch when the reward
///         budget is short.
contract NFTStakerSafePayTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;
    uint256 internal constant RATE = 100;
    uint256 internal budget;

    event Claimed(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        // Seed budget so per-second rate is exactly RATE under DEFAULT_WINDOW
        budget = staker.windowDuration() * RATE;
        phUSD.mint(owner, budget);
        vm.prank(owner);
        phUSD.approve(address(staker), budget);
        vm.prank(owner);
        staker.topUp(budget);

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    // -------------------------------------------------------------------
    // Phase 1 — shortfall reverts
    // -------------------------------------------------------------------

    /// Alice accrues some pending reward, then the contract's phUSD balance
    /// is forcibly drained below `pending`. A subsequent `claim()` must
    /// revert and leave all user state untouched.
    function test_claim_revertsWhenBalanceBelowPending() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertEq(pending, RATE * 50, "sanity: expected pending accrual");

        // Snapshot user state
        (uint256 amtBefore, uint256 debtBefore) = staker.users(alice);

        // Forcibly reduce the contract's phUSD balance below pending
        uint256 shortBalance = pending - 1;
        deal(address(phUSD), address(staker), shortBalance);
        assertLt(phUSD.balanceOf(address(staker)), pending);

        // Expect claim to revert with the exact message
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient reward balance"));
        staker.claim();

        // No event emitted, no state mutated
        (uint256 amtAfter, uint256 debtAfter) = staker.users(alice);
        assertEq(amtAfter, amtBefore, "stake amount must be untouched");
        assertEq(debtAfter, debtBefore, "rewardDebt must be untouched");
        assertEq(phUSD.balanceOf(alice), 0, "alice must receive no phUSD on revert");
    }

    /// Same scenario on the stake-restake path: a user with pre-existing
    /// pending reward that exceeds the contract balance must be blocked
    /// from top-up staking until the budget is replenished.
    function test_stake_revertsWhenBalanceBelowPendingOnRestake() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        // Drain contract below pending
        deal(address(phUSD), address(staker), pending - 1);

        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient reward balance"));
        staker.stake(5);
    }

    /// Same scenario on the unstake path.
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

    /// With sufficient balance all three paths pay the full pending and
    /// advance `user.rewardDebt` to the full accrual.
    function test_safePay_happyPathUnchanged() public {
        // claim path
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 10);
        uint256 pendingClaim = staker.pendingReward(alice);
        assertEq(pendingClaim, RATE * 10);
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice), pendingClaim);
        assertEq(staker.pendingReward(alice), 0);
        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(debt, (amt * staker.accRewardPerShare()) / staker.ACC_PRECISION());

        // stake-restake path (alice still staked)
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

        // unstake path
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

    /// `emergencyWithdraw` must still return principal even when the
    /// reward budget is too low for a normal claim to succeed.
    function test_emergencyWithdraw_stillWorksWhenBudgetShort() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        // Drain contract below pending
        deal(address(phUSD), address(staker), pending - 1);

        // Sanity: a normal claim would now revert under the new semantics
        vm.prank(alice);
        try staker.claim() {
            fail();
        } catch {}

        // Emergency escape hatch succeeds, principal returned, no phUSD paid
        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 nftBefore = nft.balanceOf(alice, ID);
        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(phUSD.balanceOf(alice), phusdBefore, "no phUSD on emergency");
        assertEq(nft.balanceOf(alice, ID) - nftBefore, 10, "principal returned");
        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    // -------------------------------------------------------------------
    // Phase 3 — claim advances rewardDebt even when pending is zero
    // -------------------------------------------------------------------

    /// Back-to-back `claim()` calls in the same block: the second call has
    /// `pending == 0` but must still leave `user.rewardDebt` equal to
    /// `user.amount * accRewardPerShare / ACC_PRECISION`. With the code
    /// shuffle in `claim` the assignment fires unconditionally, making
    /// this invariant locally visible.
    function test_claim_advancesRewardDebtEvenWhenPendingIsZero() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 25);

        vm.prank(alice);
        staker.claim();
        (uint256 amt1, uint256 debt1) = staker.users(alice);
        uint256 expected1 = (amt1 * staker.accRewardPerShare()) / staker.ACC_PRECISION();
        assertEq(debt1, expected1, "after first claim debt should match accrual");

        // Second claim, same block — pending is zero
        assertEq(staker.pendingReward(alice), 0);
        vm.prank(alice);
        staker.claim();

        (uint256 amt2, uint256 debt2) = staker.users(alice);
        uint256 expected2 = (amt2 * staker.accRewardPerShare()) / staker.ACC_PRECISION();
        assertEq(debt2, expected2, "rewardDebt must equal amount*acc/ACC_PRECISION even when pending==0");
    }
}
