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

contract NFTStakerAccrualTest is Test {
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

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Uniform price for clean per-second rate.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100); // T = 100 * 100e18

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        // Seed a large V so runway is long.
        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);

        // 30% APY on T=10_000 ether -> R = 3000e18 / SECONDS_PER_YEAR
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        rate = staker.rewardRate();
        assertGt(rate, 0);

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

        assertEq(staker.pendingReward(alice), 0);

        vm.warp(block.timestamp + 100);
        assertEq(staker.pendingReward(alice), rate * 100);
    }

    function testClaimTransfersExactPendingAndZeroes() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 expected = rate * 50;
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

        uint256 total = rate * 100;
        assertEq(staker.pendingReward(alice), total / 2);
        assertEq(staker.pendingReward(bob), total / 2);
    }

    // ---------- staker B joins halfway ----------

    function testStakerJoiningHalfwayDoesNotGetRetroactiveRewards() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);
        assertEq(staker.pendingReward(alice), rate * 100);

        vm.prank(bob);
        staker.stake(10);
        assertEq(staker.pendingReward(bob), 0);

        vm.warp(block.timestamp + 100);
        assertEq(staker.pendingReward(alice), rate * 150);
        assertEq(staker.pendingReward(bob), rate * 50);
    }

    // ---------- emissions stop past windowEnd ----------

    function testEmissionsStopPastWindowEnd() public {
        vm.prank(alice);
        staker.stake(10);

        uint256 windowEnd = staker.windowEnd();
        vm.warp(windowEnd);
        uint256 atEnd = staker.pendingReward(alice);

        vm.warp(windowEnd + 1_000);
        assertEq(staker.pendingReward(alice), atEnd, "pending should not grow past windowEnd");
    }

    function testCurrentRewardRateZeroAfterWindowEnd() public {
        assertEq(staker.currentRewardRate(), staker.rewardRate());

        vm.warp(staker.windowEnd());
        assertEq(staker.currentRewardRate(), 0);

        vm.warp(staker.windowEnd() + 1_000);
        assertEq(staker.currentRewardRate(), 0);
    }

    // ---------- accrual survives rate drop mid-window ----------

    function testAccrualSurvivesAPYDropMidWindow() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);
        uint256 oldRate = staker.rewardRate();
        uint256 oldAccrual = oldRate * 50;

        // Halve APY -> rate halves; old accrual must be preserved.
        vm.prank(owner);
        staker.setTargetAPY(0.15e18);

        // After the setter the accrual is already settled; warp another 50s
        // at the new rate.
        uint256 newRate = staker.rewardRate();
        assertLt(newRate, oldRate);

        vm.warp(block.timestamp + 50);
        uint256 total = staker.pendingReward(alice);
        // old accrual + new-rate * 50
        assertApproxEqAbs(total, oldAccrual + newRate * 50, 2);
    }

    // ---------- budget exhaustion ----------

    function testBudgetExhaustionStopsEmissionsBeforeRecompute() public {
        uint256 stakeAt = block.timestamp;
        vm.prank(alice);
        staker.stake(10);

        // Warp past windowEnd. Before any interaction triggers a
        // recompute, pendingReward must reflect the cap at windowEnd.
        uint256 endBefore = staker.windowEnd();
        vm.warp(endBefore + 10_000);

        uint256 pending = staker.pendingReward(alice);
        uint256 expectedPending = rate * (endBefore - stakeAt);
        assertEq(pending, expectedPending, "pending at exhaustion must equal rate * runway");

        // A claim at this point will recompute from current V and extend
        // windowEnd to a future time — that is the APY-target behaviour
        // and is correct. What matters is that between recomputes,
        // emissions stop cleanly at the derived window edge.
    }

    // ---------- unstake returns NFTs and pays pending ----------

    function testUnstakeReturnsPrincipalAndPaysPending() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 50);

        uint256 expectedReward = rate * 50;
        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 nftBefore = nft.balanceOf(alice, ID);

        vm.prank(alice);
        staker.unstake(10);

        assertEq(nft.balanceOf(alice, ID), nftBefore + 10);
        assertEq(phUSD.balanceOf(alice) - phusdBefore, expectedReward);
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
        emit Claimed(alice, rate * 10);
        vm.prank(alice);
        staker.claim();
    }
}
