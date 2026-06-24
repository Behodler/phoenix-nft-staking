// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerPullIntegrationTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        // Seed V then set APY so rate > 0 from the start.
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
        // SECONDS_PER_YEAR. Pre-stake a baseline so subsequent test
        // logic that reads rewardRate() pre-test-stake observes a
        // non-zero rate. Use a separate "seed" actor so alice/bob keep
        // pristine balances for their own per-test stake mutations.
        address seedStaker = address(0xCAFE);
        nft.mint(seedStaker, ID, 100);
        vm.prank(seedStaker);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(seedStaker);
        staker.stake(100);
    }

    /// Pull lands new budget BEFORE the new staker's rewardDebt is set. The
    /// new budget must not retroactively reward an incoming staker for
    /// time before they joined. Under the APY-target model with M-03
    /// sizing, V growth (via pull) only extends runway and does not
    /// retroactively bump alice's share.
    function testStakeAfterPullDoesNotRetroactivelyReward() public {
        vm.prank(alice);
        staker.stake(10);
        // alice owns 10 / (100 + 10) of total stake.

        vm.warp(block.timestamp + 50);
        uint256 alicePendingBefore = staker.pendingReward(alice);
        assertGt(alicePendingBefore, 0, "alice must have accrued");

        // New mint debt becomes available.
        hook.setPendingMint(100_000 ether);

        vm.prank(bob);
        staker.stake(10);

        // Bob's pending must be exactly zero immediately after his stake.
        assertEq(staker.pendingReward(bob), 0);
        // Alice's pending must equal what it was before (no retroactive bump).
        assertEq(staker.pendingReward(alice), alicePendingBefore);
    }

    function testStakeWithZeroHookDebtBehavesLikeNoInflow() public {
        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();
        uint256 stakedBefore = staker.totalStaked();

        hook.setPendingMint(0);

        vm.prank(alice);
        staker.stake(5);

        // Under M-03 sizing R = totalStaked * latestPrice * A /
        // SECONDS_PER_YEAR. A stake of 5 with no hook inflow grows
        // totalStaked from `stakedBefore` to `stakedBefore + 5` and the
        // rate scales accordingly. V is unchanged so budget is unchanged.
        uint256 expectedRate = rateBefore * (stakedBefore + 5) / stakedBefore;
        assertApproxEqAbs(staker.rewardRate(), expectedRate, 1);
        assertEq(staker.rewardBudget(), budgetBefore);
    }

    function testPullMidWindowSettlesAccrualFirst() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        uint256 oldRate = staker.rewardRate();
        uint256 expectedPending = staker.pendingReward(alice);
        assertGt(expectedPending, 0, "alice must have accrued");

        // Fresh debt batch — claim() pulls it and recomputes.
        hook.setPendingMint(500_000 ether);

        uint256 phusdBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();

        // Alice received exactly the pre-pull pending; the new budget did
        // not retroactively bump her share (totalStaked unchanged across
        // claim -> R unchanged).
        assertEq(phUSD.balanceOf(alice) - phusdBefore, expectedPending);

        // R stays the same (totalStaked, latestPrice, A all unchanged).
        assertEq(staker.rewardRate(), oldRate);
    }
}
