// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract NFTStakerAccrualTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;
    // Pick budget so rate is exactly 100 phUSD/sec under DEFAULT_WINDOW (540 days)
    uint256 internal RATE = 100;
    uint256 internal BUDGET;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        BUDGET = staker.windowDuration() * RATE;

        // Owner top-up to seed the schedule (no dispatcher hook needed for accrual tests)
        phUSD.mint(owner, BUDGET);
        vm.prank(owner);
        phUSD.approve(address(staker), BUDGET);
        vm.prank(owner);
        staker.topUp(BUDGET);

        // Mint NFTs and approve
        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------- single staker ----------

    function testSingleStakerAccruesAtRateTimesElapsed() public {
        vm.prank(alice);
        staker.stake(10);

        // Before any time passes, pending should be zero
        assertEq(staker.pendingReward(alice), 0);

        vm.warp(block.timestamp + 100);
        // pending = rate * elapsed (alice has 100% share)
        assertEq(staker.pendingReward(alice), RATE * 100);
    }

    function testClaimTransfersExactPendingAndZeroes() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 expected = RATE * 50;
        assertEq(staker.pendingReward(alice), expected);

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();

        assertEq(phUSD.balanceOf(alice) - balBefore, expected);
        assertEq(staker.pendingReward(alice), 0);
    }

    // ---------- two stakers, equal split ----------

    function testTwoEqualStakersSplit5050() public {
        vm.prank(alice);
        staker.stake(10);
        vm.prank(bob);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        uint256 total = RATE * 100;
        // Equal share -> half each
        assertEq(staker.pendingReward(alice), total / 2);
        assertEq(staker.pendingReward(bob), total / 2);
    }

    // ---------- staker B joins halfway ----------

    function testStakerJoiningHalfwayDoesNotGetRetroactiveRewards() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);
        // alice has earned 100 * RATE so far (solo)
        assertEq(staker.pendingReward(alice), RATE * 100);

        vm.prank(bob);
        staker.stake(10);
        // bob's pending starts at zero
        assertEq(staker.pendingReward(bob), 0);

        vm.warp(block.timestamp + 100);
        // Over the second 100 seconds the rate splits evenly: 50 to each
        // alice = solo 100s + half of 100s = 100*RATE + 50*RATE = 150*RATE
        // bob = half of 100s = 50*RATE
        assertEq(staker.pendingReward(alice), RATE * 150);
        assertEq(staker.pendingReward(bob), RATE * 50);
    }

    // ---------- emissions stop past windowEnd ----------

    function testEmissionsStopPastWindowEnd() public {
        vm.prank(alice);
        staker.stake(10);

        uint256 windowEnd = staker.windowEnd();
        // Warp to right at windowEnd
        vm.warp(windowEnd);
        uint256 atEnd = staker.pendingReward(alice);

        // Warp past
        vm.warp(windowEnd + 1_000);
        assertEq(staker.pendingReward(alice), atEnd, "pending should not grow past windowEnd");
    }

    function testCurrentRewardRateZeroAfterWindowEnd() public {
        // Before window end -> nonzero
        assertEq(staker.currentRewardRate(), staker.rewardRate());

        vm.warp(staker.windowEnd());
        // exactly at windowEnd -> still nonzero (last second eligible) — design says
        // currentRewardRate is 0 once block.timestamp >= windowEnd, so at windowEnd it's 0
        assertEq(staker.currentRewardRate(), 0);

        vm.warp(staker.windowEnd() + 1_000);
        assertEq(staker.currentRewardRate(), 0);
    }

    // ---------- budget exhaustion ----------

    function testBudgetExhaustionStopsEmissions() public {
        vm.prank(alice);
        staker.stake(10);

        // Warp past windowEnd to fully exhaust
        vm.warp(staker.windowEnd() + 1);
        // Trigger an update via claim
        vm.prank(alice);
        staker.claim();

        // rewardBudget should be (close to) zero — modulo integer truncation in rate
        // Under our setup it's exact: BUDGET = duration * RATE so depletion is clean
        assertEq(staker.rewardBudget(), 0);

        // Further warps don't grow pending
        vm.warp(block.timestamp + 1_000);
        assertEq(staker.pendingReward(alice), 0);
    }

    // ---------- unstake returns NFTs and pays pending ----------

    function testUnstakeReturnsPrincipalAndPaysPending() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);

        uint256 expectedReward = RATE * 50;
        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 nftBefore = nft.balanceOf(alice, ID);

        vm.prank(alice);
        staker.unstake(10);

        assertEq(nft.balanceOf(alice, ID), nftBefore + 10);
        assertEq(phUSD.balanceOf(alice) - phusdBefore, expectedReward);
        // After full unstake amount goes to zero
        (uint256 amt,) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(staker.totalStaked(), 0);
    }

    function testUnstakeMoreThanStakedReverts() public {
        vm.prank(alice);
        staker.stake(10);
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: insufficient stake"));
        staker.unstake(11);
    }

    function testStakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: zero stake"));
        staker.stake(0);
    }

    function testUnstakeZeroReverts() public {
        vm.prank(alice);
        staker.stake(1);
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: zero unstake"));
        staker.unstake(0);
    }

    // ---------- events ----------

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

    function testStakeEmitsStakedEvent() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit Staked(alice, 5);
        vm.prank(alice);
        staker.stake(5);
    }

    function testUnstakeEmitsUnstakedEvent() public {
        vm.prank(alice);
        staker.stake(5);
        vm.expectEmit(true, true, true, true, address(staker));
        emit Unstaked(alice, 3);
        vm.prank(alice);
        staker.unstake(3);
    }

    function testClaimEmitsClaimedEventWhenNonZero() public {
        vm.prank(alice);
        staker.stake(5);
        vm.warp(block.timestamp + 10);
        vm.expectEmit(true, true, true, true, address(staker));
        emit Claimed(alice, RATE * 10);
        vm.prank(alice);
        staker.claim();
    }
}
