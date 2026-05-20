// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerV2} from "../src/NFTStakerV2.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice V1 regression smoke for the refactored `_safePay(recipient, amount)`.
///         Confirms that direct user actions (stake / unstake / claim /
///         emergencyWithdraw) still route the reward (or principal) to
///         `msg.sender`. The deep accrual / APY / sustainability math is
///         exercised against `NFTStaker.sol` (V1) in the existing suite and
///         is byte-identical in V2, so it is not duplicated here.
contract NFTStakerV2Test is Test {
    NFTStakerV2 internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStakerV2(
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

        nft.mint(alice, ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function test_stake_paysPendingToMsgSender() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);

        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.stake(5);
        assertEq(phUSD.balanceOf(alice) - balBefore, pending);
    }

    function test_unstake_paysPendingToMsgSenderAndReturnsNFTs() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);

        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        uint256 phBefore = phUSD.balanceOf(alice);
        uint256 nftBefore = nft.balanceOf(alice, ID);

        vm.prank(alice);
        staker.unstake(10);

        assertEq(phUSD.balanceOf(alice) - phBefore, pending);
        assertEq(nft.balanceOf(alice, ID) - nftBefore, 10);
    }

    function test_claim_paysPendingToMsgSender() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice) - balBefore, pending);
        assertEq(staker.pendingReward(alice), 0);
    }

    function test_emergencyWithdraw_returnsPrincipalToMsgSender() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);

        uint256 nftBefore = nft.balanceOf(alice, ID);
        uint256 phBefore = phUSD.balanceOf(alice);

        vm.prank(alice);
        staker.emergencyWithdraw();

        // Principal returns to msg.sender; pending reward is forfeited.
        assertEq(nft.balanceOf(alice, ID) - nftBefore, 10);
        assertEq(phUSD.balanceOf(alice), phBefore);

        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    function test_solvencyInvariantHolds_acrossStakeClaimUnstake() public {
        // balance == rewardBudget + committedDebt at every observable boundary.
        _assertSolvency();

        vm.prank(alice);
        staker.stake(10);
        _assertSolvency();

        vm.warp(block.timestamp + 25);
        vm.prank(alice);
        staker.claim();
        _assertSolvency();

        vm.warp(block.timestamp + 25);
        vm.prank(alice);
        staker.unstake(10);
        _assertSolvency();
    }

    function _assertSolvency() internal view {
        uint256 bal = phUSD.balanceOf(address(staker));
        assertEq(bal, staker.rewardBudget() + staker.committedDebt(), "solvency invariant broken");
    }
}
