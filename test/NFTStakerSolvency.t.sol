// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Audit M-01 regression suite. The bug: `_recomputeSchedule`
///         unconditionally reset `rewardBudget = V` after `_updatePool` had
///         just moved committed accrual into `accRewardPerShare`, causing the
///         contract to over-promise on the next runway and DoSing late
///         claimers via `_safePay`'s shortfall revert.
///
///         The fix introduces a contract-level `committedDebt` state variable
///         maintained by `_updatePool` (++) and `_safePay` (--). The new
///         invariant `balance == rewardBudget + committedDebt` holds at all
///         times, not just at recompute boundaries.
///
///         This file pins:
///           - Reproduction of the M-01 PoC scenario (Alice/Bob 30-day setup).
///           - The strong solvency invariant after every state-mutating call.
///           - `totalDebt()` reflects `committedDebt + in-flight accrual`.
contract NFTStakerSolvencyTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    /// @dev M-01 PoC parameters.
    uint256 internal constant N = 100;
    uint256 internal constant PRICE = 100 ether;
    uint256 internal constant SEED = 3_000 ether; // ~1 year runway at 30% APY
    uint256 internal constant TARGET_APY = 0.3e18;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), PRICE, 0, false);
        nftMinter.setTotalSupply(ID, N);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        phUSD.mint(owner, SEED);
        vm.prank(owner);
        phUSD.approve(address(staker), SEED);
        vm.prank(owner);
        staker.topUp(SEED);

        vm.prank(owner);
        staker.setTargetAPY(TARGET_APY);

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    // -------------------------------------------------------------------
    // M-01 PoC — Bob's claim must NOT revert under correct bookkeeping
    // -------------------------------------------------------------------

    /// @notice Reproduces the audit submission's Alice/Bob scenario.
    ///         Alice stakes; 30 days elapse; Bob stakes (recompute fires).
    ///         Under the buggy code, the recompute re-inflates rewardBudget
    ///         to the full V despite ~246 ether already being committed to
    ///         Alice via accRewardPerShare. After Alice claims, Bob's claim
    ///         reverts with "insufficient reward balance" because the
    ///         contract has over-promised. Under the fix this test passes.
    function test_M01_BobsClaim_succeeds_after_30_day_gap() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 30 days);

        // Bob's stake triggers _syncBudget -> _updatePool (commits Alice's
        // 30-day accrual) -> _recomputeSchedule. Under the buggy code, the
        // recompute would over-promise here.
        vm.prank(bob);
        staker.stake(10);

        // Wind to windowEnd so all pending is fully accrued.
        vm.warp(staker.windowEnd() + 1);

        // Alice claims first — under the buggy code this drained the
        // contract below what was promised to Bob.
        vm.prank(alice);
        staker.claim();

        // Bob's claim must succeed. This is the core M-01 fix.
        vm.prank(bob);
        staker.claim();

        // Total payouts must not exceed the seeded budget.
        uint256 paid = phUSD.balanceOf(alice) + phUSD.balanceOf(bob);
        assertLe(paid, SEED, "total paid exceeds seeded budget");
    }

    // -------------------------------------------------------------------
    // Strong invariant: balance == rewardBudget + committedDebt at all times
    // -------------------------------------------------------------------

    function _assertSolvency(string memory label) internal view {
        uint256 balance = phUSD.balanceOf(address(staker));
        uint256 budget = staker.rewardBudget();
        uint256 committed = staker.committedDebt();
        assertEq(balance, budget + committed, label);
    }

    function test_solvency_invariant_holds_after_every_state_change() public {
        // After deploy + topUp + setTargetAPY (all in setUp).
        _assertSolvency("after setUp");

        // First stake.
        vm.prank(alice);
        staker.stake(10);
        _assertSolvency("after alice.stake");

        // Time warp + claim.
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        staker.claim();
        _assertSolvency("after alice.claim");

        // Additional stake (bob).
        vm.prank(bob);
        staker.stake(15);
        _assertSolvency("after bob.stake");

        // Unstake.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staker.unstake(5);
        _assertSolvency("after alice.unstake");

        // topUp.
        uint256 extra = 500 ether;
        phUSD.mint(owner, extra);
        vm.prank(owner);
        phUSD.approve(address(staker), extra);
        vm.prank(owner);
        staker.topUp(extra);
        _assertSolvency("after topUp");

        // pullAndRefresh (no hook configured -> pure recompute).
        vm.prank(owner);
        staker.pullAndRefresh();
        _assertSolvency("after pullAndRefresh");

        // setTargetAPY (calls _updatePool then _recompute).
        vm.prank(owner);
        staker.setTargetAPY(0.2e18);
        _assertSolvency("after setTargetAPY");
    }

    // -------------------------------------------------------------------
    // totalDebt() reflects committedDebt + in-flight accrual
    // -------------------------------------------------------------------

    function test_totalDebt_equals_committedDebt_plus_pending_accrual() public {
        vm.prank(alice);
        staker.stake(10);

        // Immediately after stake, _updatePool ran but no time elapsed so
        // committed should be 0 and pending also 0.
        assertEq(staker.committedDebt(), 0, "committedDebt should be 0 right after stake");
        assertEq(staker.totalDebt(), 0, "totalDebt should be 0 right after stake");

        // Warp without claiming: totalDebt should equal in-flight accrual,
        // committedDebt unchanged.
        vm.warp(block.timestamp + 100);
        uint256 rate = staker.rewardRate();
        uint256 expectedAccrual = rate * 100;

        assertEq(staker.committedDebt(), 0, "committedDebt before any update");
        assertEq(staker.totalDebt(), expectedAccrual, "totalDebt mid-window");

        // Trigger an _updatePool (via a non-payout setter we can call without
        // a hook): just stake again. After staking, the prior accrual is
        // committed and totalDebt should match committedDebt exactly.
        vm.prank(bob);
        staker.stake(10);

        // committedDebt should now reflect the full 100s of emissions Alice
        // accrued (within rounding).
        assertApproxEqAbs(staker.committedDebt(), expectedAccrual, 2, "committedDebt after settlement");
        // No further time has passed so totalDebt == committedDebt.
        assertEq(staker.totalDebt(), staker.committedDebt(), "totalDebt == committedDebt at settlement");
    }

    // -------------------------------------------------------------------
    // Edge case: V < committedDebt at recompute pins budget to 0
    // -------------------------------------------------------------------

    /// @notice If hook misbehaviour or hook removal reduces V below the
    ///         already-committed debt, the recompute must clamp budget to 0
    ///         rather than reverting. Principal escape via emergencyWithdraw
    ///         is the safety valve.
    function test_recompute_when_V_below_committedDebt_pins_budget_to_zero() public {
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        vm.prank(alice);
        staker.stake(10);

        // Accrue some committed debt, then drain balance below committed
        // and clear hook so V = balance < committedDebt.
        vm.warp(block.timestamp + 10 days);

        // Force a settlement so committedDebt is non-trivial.
        vm.prank(owner);
        staker.pullAndRefresh();

        uint256 committedBefore = staker.committedDebt();
        assertGt(committedBefore, 0, "committedDebt must be non-zero for this test");

        // Drain the contract balance below committedDebt by spoofing the
        // balance via deal. (Mimics the hook misbehaviour scenario where
        // mintDebt drops faster than pulls deliver.)
        deal(address(phUSD), address(staker), committedBefore / 2);

        // Trigger another recompute. Must not revert and must pin budget
        // to 0 because V < committedDebt.
        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardBudget(), 0, "budget must clamp to 0 when V < committedDebt");
    }

    // -------------------------------------------------------------------
    // emergencyWithdraw decrements committedDebt (option-1 strict)
    // -------------------------------------------------------------------

    function test_emergencyWithdraw_decrements_committedDebt() public {
        vm.prank(alice);
        staker.stake(10);
        vm.prank(bob);
        staker.stake(10);

        vm.warp(block.timestamp + 5 days);

        // Settle accrual into committedDebt via a recompute.
        vm.prank(owner);
        staker.pullAndRefresh();

        uint256 alicePendingBefore = staker.pendingReward(alice);
        uint256 bobPendingBefore = staker.pendingReward(bob);
        uint256 committedBefore = staker.committedDebt();

        // Both alice and bob have equal stake and equal pending.
        assertApproxEqAbs(alicePendingBefore, bobPendingBefore, 2);
        assertApproxEqAbs(committedBefore, alicePendingBefore + bobPendingBefore, 2);

        // Alice emergency-withdraws — forfeits her pending.
        vm.prank(alice);
        staker.emergencyWithdraw();

        // committedDebt should decrement by alice's forfeited pending.
        // The remaining committedDebt should equal bob's still-claimable
        // pending.
        uint256 bobPendingAfter = staker.pendingReward(bob);
        assertApproxEqAbs(staker.committedDebt(), bobPendingAfter, 2, "committedDebt mismatched bob's pending");

        // And the strong invariant still holds (no emergency call to
        // _recomputeSchedule, but bookkeeping is consistent).
        _assertSolvency("after alice emergencyWithdraw");
    }
}
