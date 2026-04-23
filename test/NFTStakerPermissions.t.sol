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

/// @notice Covers the decision table for the `ownerOrNotGriefed` modifier on
///         `topUp` and `pullAndRefresh`. A non-owner caller is allowed iff
///         the call does not reduce `rewardRate`, or the window was already
///         expired going into the call. The owner bypasses the guard
///         unconditionally.
contract NFTStakerPermissionsTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal stranger = address(0xBEEF);
    address internal user = address(0xA1);

    uint256 internal constant INITIAL_ID = 1;
    uint256 internal constant STAKE_AMOUNT = 10;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), INITIAL_ID, IERC20(address(phUSD)), owner);
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        // Seed the NFT for the user + approve.
        nft.mint(user, INITIAL_ID, STAKE_AMOUNT);
        vm.prank(user);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Owner funds with `amount` via topUp. Used to seed a non-zero
    ///      rewardRate in the "rate would fall" scenarios.
    function _ownerSeed(uint256 amount) internal {
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);
        vm.prank(owner);
        staker.topUp(amount);
    }

    /// @dev Stake STAKE_AMOUNT on behalf of `user`. Used to engage _updatePool
    ///      drain on subsequent time warps.
    function _userStake() internal {
        vm.prank(user);
        staker.stake(STAKE_AMOUNT);
    }

    // ---------------------------------------------------------------------
    // pullAndRefresh — non-owner, permitted paths
    // ---------------------------------------------------------------------

    function test_pullAndRefresh_zeroInflow_nonOwnerSucceeds() public {
        // Seed so there is a meaningful schedule to compare against.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);

        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();
        uint256 endBefore = staker.windowEnd();

        hook.setPendingMint(0);
        vm.prank(stranger);
        staker.pullAndRefresh();

        // No inflow => _syncBudget early-returns after _updatePool, so with
        // no stakers rewardRate/rewardBudget/windowEnd are all unchanged.
        assertEq(staker.rewardRate(), rateBefore, "rate changed on zero pull");
        assertEq(staker.rewardBudget(), budgetBefore, "budget changed on zero pull");
        assertEq(staker.windowEnd(), endBefore, "window changed on zero pull");
    }

    function test_pullAndRefresh_unsetHook_nonOwnerSucceeds() public {
        // Seed then unset hook.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(0)));

        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();
        uint256 endBefore = staker.windowEnd();

        vm.prank(stranger);
        staker.pullAndRefresh();

        assertEq(staker.rewardRate(), rateBefore, "rate changed on unset-hook pull");
        assertEq(staker.rewardBudget(), budgetBefore, "budget changed on unset-hook pull");
        assertEq(staker.windowEnd(), endBefore, "window changed on unset-hook pull");
    }

    function test_pullAndRefresh_rateRises_nonOwnerSucceeds() public {
        // Fresh contract, rate == 0. Any positive inflow raises the rate.
        uint256 amount = 540 days * 100;
        hook.setPendingMint(amount);

        vm.prank(stranger);
        staker.pullAndRefresh();

        assertGt(staker.rewardRate(), 0, "rate did not rise from zero");
        assertEq(staker.rewardBudget(), amount);
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
    }

    // ---------------------------------------------------------------------
    // pullAndRefresh — rate-falls: revert vs owner bypass
    // ---------------------------------------------------------------------

    /// @dev Build a fixture where a tiny pull mid-window will reduce the rate.
    ///      Seed large as owner, stake, warp half-way through the window,
    ///      then set hook pending to 1 wei. After _updatePool drains the
    ///      budget over ~windowDuration/2 at the current rate, adding 1 wei
    ///      and recomputing rate = budget/windowDuration produces a strictly
    ///      lower rate.
    function _seedRateFallFixture() internal returns (uint256 seed) {
        seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        // Warp half-way through the window so _updatePool drains a meaningful
        // amount at the current (high) rate.
        vm.warp(block.timestamp + staker.windowDuration() / 2);
        hook.setPendingMint(1);
    }

    function test_pullAndRefresh_rateFalls_nonOwnerReverts() public {
        _seedRateFallFixture();

        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();
        uint256 endBefore = staker.windowEnd();

        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStaker: reward rate reduced"));
        staker.pullAndRefresh();

        // Revert rolls back all state changes.
        assertEq(staker.rewardRate(), rateBefore, "rate changed after revert");
        assertEq(staker.rewardBudget(), budgetBefore, "budget changed after revert");
        assertEq(staker.windowEnd(), endBefore, "window changed after revert");
    }

    function test_pullAndRefresh_rateFalls_ownerSucceeds() public {
        _seedRateFallFixture();

        uint256 rateBefore = staker.rewardRate();

        vm.prank(owner);
        staker.pullAndRefresh();

        // Rate falls as expected; owner bypass allowed it.
        assertLt(staker.rewardRate(), rateBefore, "rate did not fall under owner call");
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
    }

    // ---------------------------------------------------------------------
    // pullAndRefresh — large mid-window inflow still succeeds for strangers
    // ---------------------------------------------------------------------

    function test_pullAndRefresh_largeInflow_rateRises_nonOwnerSucceeds() public {
        // Seed, stake, warp mid-window, then a large inflow that more than
        // compensates for the drain and raises the rate.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        vm.warp(block.timestamp + staker.windowDuration() / 2);

        uint256 rateBefore = staker.rewardRate();
        uint256 large = 540 days * 200;
        hook.setPendingMint(large);

        vm.prank(stranger);
        staker.pullAndRefresh();

        assertGt(staker.rewardRate(), rateBefore, "rate did not rise on large pull");
    }

    // ---------------------------------------------------------------------
    // topUp — non-owner, rate rises
    // ---------------------------------------------------------------------

    function test_topUp_rateRises_nonOwnerSucceeds() public {
        // Fresh contract, rate == 0. Stranger funds -> rate > 0 = old.
        uint256 amount = 540 days * 100;
        phUSD.mint(stranger, amount);
        vm.prank(stranger);
        phUSD.approve(address(staker), amount);

        vm.prank(stranger);
        staker.topUp(amount);

        assertGt(staker.rewardRate(), 0, "rate did not rise from zero on stranger topUp");
        assertEq(staker.rewardBudget(), amount);
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
        assertEq(phUSD.balanceOf(address(staker)), amount);
    }

    // ---------------------------------------------------------------------
    // topUp — non-owner, rate falls -> revert; owner same fixture -> success
    // ---------------------------------------------------------------------

    function _seedTopUpRateFallFixture() internal {
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        vm.warp(block.timestamp + staker.windowDuration() / 2);
    }

    function test_topUp_rateFalls_nonOwnerReverts() public {
        _seedTopUpRateFallFixture();

        // Stranger mints and approves a tiny amount.
        phUSD.mint(stranger, 1);
        vm.prank(stranger);
        phUSD.approve(address(staker), 1);

        uint256 rateBefore = staker.rewardRate();
        uint256 budgetBefore = staker.rewardBudget();
        uint256 endBefore = staker.windowEnd();

        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStaker: reward rate reduced"));
        staker.topUp(1);

        assertEq(staker.rewardRate(), rateBefore, "rate changed after revert");
        assertEq(staker.rewardBudget(), budgetBefore, "budget changed after revert");
        assertEq(staker.windowEnd(), endBefore, "window changed after revert");
    }

    function test_topUp_rateFalls_ownerSucceeds() public {
        _seedTopUpRateFallFixture();

        phUSD.mint(owner, 1);
        vm.prank(owner);
        phUSD.approve(address(staker), 1);

        uint256 rateBefore = staker.rewardRate();

        vm.prank(owner);
        staker.topUp(1);

        assertLt(staker.rewardRate(), rateBefore, "owner topUp did not lower rate");
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
    }

    // ---------------------------------------------------------------------
    // topUp — zero amount always reverts (body guard fires before modifier)
    // ---------------------------------------------------------------------

    function test_topUp_zeroAmount_ownerStillReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }

    function test_topUp_zeroAmount_strangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }

    // ---------------------------------------------------------------------
    // Expired-window bypass
    // ---------------------------------------------------------------------

    function test_pullAndRefresh_expiredWindow_nonOwnerRestartsEvenAtLowerRate() public {
        // Seed large, stake, warp past windowEnd, then tiny inflow.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        // Warp strictly past windowEnd.
        vm.warp(staker.windowEnd() + 1);
        assertGe(block.timestamp, staker.windowEnd(), "not past windowEnd");

        // Tiny inflow via the hook.
        hook.setPendingMint(1);

        uint256 rateBefore = staker.rewardRate();

        vm.prank(stranger);
        staker.pullAndRefresh();

        // Rate must have fallen to something below the old seeded rate.
        assertLt(staker.rewardRate(), rateBefore, "rate did not fall on expired-window restart");
        // Window reset to now + windowDuration.
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration(), "window did not reset");
    }

    function test_topUp_expiredWindow_nonOwnerRestartsEvenAtLowerRate() public {
        // Seed large, stake, warp past windowEnd, then stranger tops up tiny.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        vm.warp(staker.windowEnd() + 1);
        assertGe(block.timestamp, staker.windowEnd(), "not past windowEnd");

        // Stranger mints and approves a tiny amount.
        phUSD.mint(stranger, 1);
        vm.prank(stranger);
        phUSD.approve(address(staker), 1);

        uint256 rateBefore = staker.rewardRate();

        vm.prank(stranger);
        staker.topUp(1);

        assertLt(staker.rewardRate(), rateBefore, "rate did not fall on expired-window restart via topUp");
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration(), "window did not reset");
    }

    function test_expiredWindowBypass_onlyAppliesToFirstRestart() public {
        // Seed, stake, warp past windowEnd.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();
        vm.warp(staker.windowEnd() + 1);

        // Stranger A restarts with an inflow big enough to produce a nonzero
        // rate (rate must be > 0 for the monotonicity check on B to have
        // a meaningful floor to fall below). Pick `windowDuration * 10`
        // so rate settles to 10 phUSD/sec post-restart.
        uint256 aAmount = staker.windowDuration() * 10;
        phUSD.mint(stranger, aAmount);
        vm.prank(stranger);
        phUSD.approve(address(staker), aAmount);
        vm.prank(stranger);
        staker.topUp(aAmount);

        // After A's successful restart the new window is active.
        assertGt(staker.windowEnd(), block.timestamp, "window did not re-engage");
        assertGt(staker.rewardRate(), 0, "rate did not engage on restart");

        // Stranger B tries to pull with a tiny pending mint after some drain.
        // With drain > tiny, post-drain budget + tiny divided over the fresh
        // window is strictly below the pre rate, so the rate-monotonicity
        // branch must revert.
        address strangerB = address(0xFACE);
        vm.warp(block.timestamp + staker.windowDuration() / 4);
        hook.setPendingMint(1);

        uint256 rateBefore = staker.rewardRate();
        uint256 endBefore = staker.windowEnd();

        vm.prank(strangerB);
        vm.expectRevert(bytes("NFTStaker: reward rate reduced"));
        staker.pullAndRefresh();

        // State unchanged after revert.
        assertEq(staker.rewardRate(), rateBefore);
        assertEq(staker.windowEnd(), endBefore);
    }
}
