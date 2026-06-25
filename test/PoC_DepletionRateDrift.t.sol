// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {NFTStakerDepletion} from "../src/NFTStakerDepletion.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";
import {MockUniboostMintDebtHook} from "./mocks/MockUniboostMintDebtHook.sol";

/// @title M-01 regression (INVERTED PoC): linear-depletion / rate-drift FIXED
///
/// @notice This file is the inverted descendant of the audit PoC
///         `PoC_DepletionRateDrift.t.sol` (DEDUP-18-001). The original PoC
///         PROVED the bug — an ACTIVE staker who interacts frequently
///         systematically under-earned versus a PASSIVE staker with an
///         identical position over the same horizon, because
///         `_recomputeSchedule` was invoked on EVERY interaction via
///         `_syncBudget` (even when the dispatcher hook was unset and the
///         actual inflow was provably ZERO), re-deriving the rate against the
///         shrinking remaining budget and pushing `windowEnd` a fresh full
///         window into the future each time.
///
///         Post-fix (story-020 / audit M-01), `_syncBudget` only recomputes
///         when a `pull()` actually brings funds in (`inflow > 0`), and the
///         stake/unstake tail recomputes are removed. A bare interaction no
///         longer resets the deadline or re-derives the rate. The assertions
///         below are the INVERSION of the original PoC:
///
///           - active ≈ passive (both receive ≈ the full budget over the
///             committed window, within floor-rounding tolerance);
///           - `windowEnd` does NOT move on a zero-inflow `claim`;
///           - the rate does NOT decay across interactions;
///           - nothing is stranded beyond floor dust.
///
///         SOLVENCY: `balance == rewardBudget + committedDebt` holds throughout
///         (it always did — the bug was misallocation/timing, not theft).
contract PoC_DepletionRateDriftTest is Test {
    NFTStakerDepletion internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal passive = address(0xA551E);
    address internal active = address(0xAC71E);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_MONTH = 365 days / 12;
    uint256 internal constant MONTHS = 12; // 12-month committed depletion window
    uint256 internal constant WINDOW = MONTHS * SECONDS_PER_MONTH; // == 365 days

    // A realistic fixed reward budget. Hook is intentionally LEFT UNSET so the
    // pull() inflow is genuinely zero — exactly the bare-interaction scenario
    // the fix must leave the schedule untouched on.
    uint256 internal constant BUDGET = 1_200_000 ether;
    uint256 internal constant STAKE = 10; // identical ERC1155 stake in both scenarios

    function setUp() public {
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);
    }

    /// @dev Deploys a fresh, hook-less staker pre-funded with BUDGET, with `who`
    ///      holding STAKE units, and the 12-month window set. Returns the start ts.
    function _freshStaker(address who) internal returns (uint256 startTs) {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");

        staker = new NFTStakerDepletion(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
        // Fund the budget; hook deliberately NOT set -> inflow is always zero.
        phUSD.mint(address(staker), BUDGET);

        nft.mint(who, ID, STAKE);
        vm.prank(who);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(who);
        staker.stake(STAKE);

        vm.prank(owner);
        staker.setDepletionWindow(MONTHS);

        startTs = block.timestamp;
    }

    function _assertSolvency() internal view {
        // Strong invariant: held balance == rewardBudget + committedDebt.
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "SOLVENCY BREACHED: balance != rewardBudget + committedDebt"
        );
    }

    // ------------------------------------------------------------------
    // The contrast: passive vs active over the SAME 12-month horizon.
    // Post-fix they must agree.
    // ------------------------------------------------------------------

    function test_M01_activeMatchesPassive_noRateDrift() public {
        // ============================================================
        // SCENARIO A — PASSIVE staker: never interacts during the window,
        // claims exactly once at windowEnd. Linear depletion as intended.
        // ============================================================
        uint256 startTs = _freshStaker(passive);
        uint256 initialRate = staker.rewardRate();
        uint256 initialWindowEnd = staker.windowEnd();
        assertEq(initialWindowEnd, startTs + WINDOW, "window must start at now + 365 days");
        _assertSolvency();

        // Warp to exactly the original windowEnd and claim ONCE.
        vm.warp(startTs + WINDOW);
        vm.prank(passive);
        staker.claim();
        uint256 passiveTotal = phUSD.balanceOf(passive);
        _assertSolvency();

        // ============================================================
        // SCENARIO B — ACTIVE staker: identical position, identical budget,
        // identical window, but calls claim() once per day for 365 days.
        // ============================================================
        _freshStaker(active); // fresh deployment, resets block timestamp baseline
        uint256 startTsB = block.timestamp;
        assertEq(staker.rewardRate(), initialRate, "active scenario must start at the SAME rate");
        uint256 windowEndB = staker.windowEnd();

        for (uint256 d = 0; d < 365; d++) {
            vm.warp(startTsB + (d + 1) * 1 days);
            vm.prank(active);
            staker.claim();
            _assertSolvency(); // solvency holds on EVERY interaction
            // INVERTED: windowEnd must NOT move on a zero-inflow claim.
            assertEq(staker.windowEnd(), windowEndB, "windowEnd must NOT move on a zero-inflow claim");
            // INVERTED: the rate must NOT decay across interactions.
            assertEq(staker.rewardRate(), initialRate, "rewardRate must NOT decay across bare interactions");
        }

        uint256 activeTotal = phUSD.balanceOf(active);
        uint256 finalRate = staker.rewardRate();
        uint256 finalWindowEnd = staker.windowEnd();
        uint256 stranded = phUSD.balanceOf(address(staker)); // budget left behind

        // ---- Observed numbers ----
        console2.log("=== M-01 (FIXED): active vs passive linear depletion ===");
        console2.log("passive total received (wei)   :", passiveTotal);
        console2.log("active  total received (wei)   :", activeTotal);
        console2.log("stranded in contract (wei)     :", stranded);
        console2.log("initial rewardRate (wei/s)     :", initialRate);
        console2.log("final   rewardRate (wei/s)     :", finalRate);
        console2.log("original windowEnd             :", startTsB + WINDOW);
        console2.log("final   windowEnd              :", finalWindowEnd);

        // ---- ASSERTIONS (inverted from the PoC) ----

        // 1. Passive staker collects ~the full budget (floor dust < windowSeconds wei).
        assertApproxEqRel(passiveTotal, BUDGET, 1e12, "passive should receive ~full budget");

        // 2. FIX: the active staker receives ~the SAME as the passive staker over
        //    the SAME horizon (both ≈ full budget, within floor-rounding tolerance).
        assertApproxEqRel(activeTotal, passiveTotal, 1e12, "active must match passive (no rate-drift)");
        assertApproxEqRel(activeTotal, BUDGET, 1e12, "active should receive ~full budget");

        // 3. FIX: nothing material is stranded — only floor dust remains.
        assertLt(stranded, (BUDGET * 1) / 100, "no material budget may be stranded after the fix");

        // 4. FIX: windowEnd did NOT drift — it stayed at the original deadline.
        assertEq(finalWindowEnd, startTsB + WINDOW, "windowEnd must NOT drift past the original deadline");

        // 5. FIX: the rate did NOT decay.
        assertEq(finalRate, initialRate, "rewardRate must NOT decay across bare interactions");

        // 6. Solvency held throughout; every phUSD is conserved.
        _assertSolvency();
        assertEq(activeTotal + stranded, BUDGET, "active received + stranded must equal the full budget (no theft)");
    }

    // ------------------------------------------------------------------
    // Restart-on-mint preserved: with the hook set, a non-zero pull mid-window
    // DOES restart windowEnd = now + windowSeconds and re-derive the rate upward.
    // ------------------------------------------------------------------

    function test_M01_restartOnMint_preserved() public {
        uint256 startTs = _freshStaker(passive);
        uint256 initialRate = staker.rewardRate();
        assertEq(staker.windowEnd(), startTs + WINDOW, "window starts at now + 365 days");

        // Wire a hook that will mint fresh budget on the next pull.
        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));

        // Advance a quarter into the window, then a new NFT mint adds budget.
        uint256 midTs = startTs + WINDOW / 4;
        vm.warp(midTs);
        hook.setPendingMint(BUDGET); // doubles the budget on pull

        vm.prank(passive);
        staker.claim(); // claim() -> _syncBudget -> pull() brings inflow > 0 -> recompute

        // windowEnd restarted from now; rate re-derived upward against the bigger budget.
        assertEq(staker.windowEnd(), midTs + WINDOW, "non-zero pull must restart windowEnd = now + windowSeconds");
        assertGt(staker.rewardRate(), initialRate, "non-zero pull must re-derive the rate UPWARD (budget grew)");
        _assertSolvency();
    }

    // ------------------------------------------------------------------
    // Zero-inflow no-op: a pullAndRefresh() with the hook set but no pending
    // mint (inflow == 0) leaves rewardRate and windowEnd unchanged.
    // ------------------------------------------------------------------

    function test_M01_zeroInflowPullAndRefresh_isNoop() public {
        uint256 startTs = _freshStaker(passive);
        uint256 rateBefore = staker.rewardRate();
        uint256 windowEndBefore = staker.windowEnd();

        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));
        // hook.pendingMint == 0 -> pull() is a no-op -> inflow == 0.

        // Advance some time, then manually refresh — accrual settles but the
        // schedule (rate + windowEnd) must be untouched.
        vm.warp(startTs + WINDOW / 3);
        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardRate(), rateBefore, "zero-inflow pullAndRefresh must NOT change rewardRate");
        assertEq(staker.windowEnd(), windowEndBefore, "zero-inflow pullAndRefresh must NOT move windowEnd");
        _assertSolvency();

        // A bare claim() with the same zero-inflow hook is likewise a schedule no-op.
        vm.warp(startTs + WINDOW / 2);
        vm.prank(passive);
        staker.claim();
        assertEq(staker.rewardRate(), rateBefore, "zero-inflow claim must NOT change rewardRate");
        assertEq(staker.windowEnd(), windowEndBefore, "zero-inflow claim must NOT move windowEnd");
        _assertSolvency();
    }
}
