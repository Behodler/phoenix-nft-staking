// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

contract NFTStakerPullIntegrationTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant ID = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    /// Pull lands new budget BEFORE the new staker's rewardDebt is set. The
    /// new budget must not retroactively reward the staker for time before
    /// they joined; that pre-pull elapsed time accrued at the pre-pull rate.
    function testStakeAfterPullDoesNotRetroactivelyReward() public {
        // Seed initial schedule
        uint256 initialBudget = staker.windowDuration() * 100;
        hook.setPendingMint(initialBudget);
        // Trigger pull explicitly so we control the timeline
        staker.pullAndRefresh();

        // Alice stakes early, accrues solo
        vm.prank(alice);
        staker.stake(10);

        // Time passes, then debt builds at the hook
        vm.warp(block.timestamp + 50);

        // New batch of debt is now pending — it should fold into the schedule
        // when bob stakes, but the previous 50s should accrue at the OLD rate
        // (i.e. all to alice, none to bob).
        uint256 secondBatch = staker.windowDuration() * 200;
        hook.setPendingMint(secondBatch);

        uint256 alicePendingBefore = staker.pendingReward(alice);
        // Sanity: alice was solo for 50s at rate ~100/sec (rounded down)
        assertEq(alicePendingBefore, staker.rewardRate() * 50);

        vm.prank(bob);
        staker.stake(10);

        // Bob's pending must be exactly zero immediately after his stake
        assertEq(staker.pendingReward(bob), 0);

        // Alice's pending must equal what it was before bob's stake (no
        // retroactive change from the pull-induced rate increase)
        uint256 alicePendingAfter = staker.pendingReward(alice);
        assertEq(alicePendingAfter, alicePendingBefore);
    }

    function testStakeWithZeroHookDebtBehavesLikePrePullSchedule() public {
        // Seed initial schedule
        uint256 initialBudget = staker.windowDuration() * 100;
        hook.setPendingMint(initialBudget);
        staker.pullAndRefresh();

        uint256 endBefore = staker.windowEnd();
        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();

        // No pending mint
        hook.setPendingMint(0);

        // alice stakes — implicit pull yields zero, so schedule untouched
        vm.prank(alice);
        staker.stake(5);

        assertEq(staker.windowEnd(), endBefore);
        assertEq(staker.rewardRate(), rateBefore);
        assertEq(staker.rewardBudget(), budgetBefore);
    }

    function testPullMidWindowSettlesAccrualAtOldRateFirst() public {
        // Seed initial schedule
        uint256 initialBudget = staker.windowDuration() * 100;
        hook.setPendingMint(initialBudget);
        staker.pullAndRefresh();

        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        // alice has solo'd for 100s at the old rate
        uint256 expectedPending = staker.rewardRate() * 100;
        assertEq(staker.pendingReward(alice), expectedPending);

        // Now a fresh debt batch — claim() will pull and reset schedule.
        // The accrual from the previous 100s must already be in
        // accRewardPerShare (i.e. claimed) before the rate changes.
        hook.setPendingMint(staker.windowDuration() * 200);

        uint256 phusdBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();

        // Alice received exactly the pre-pull pending; the new budget did not
        // retroactively bump her share.
        assertEq(phUSD.balanceOf(alice) - phusdBefore, expectedPending);

        // After the implicit pull rate is the new (combined) one
        // budget = (initialBudget - claimed) + secondBatch
        uint256 expectedBudget = (initialBudget - expectedPending) + staker.windowDuration() * 200;
        assertEq(staker.rewardBudget(), expectedBudget);
        assertEq(staker.rewardRate(), expectedBudget / staker.windowDuration());
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
    }
}
