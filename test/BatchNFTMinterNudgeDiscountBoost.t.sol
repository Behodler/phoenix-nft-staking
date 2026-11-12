// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BatchNFTMinterNudgeDiscount} from "../src/BatchNFTMinterNudgeDiscount.sol";
import {NudgeStreamer} from "../src/NudgeStreamer.sol";
import {IMintDebtRatio} from "../src/interfaces/IMintDebtRatio.sol";
import {NudgeDiscountFixture} from "./BatchNFTMinterNudgeDiscount.t.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";

/// @title BatchNFTMinterNudgeDiscount — audit-27 M-01 cap + overflow boost, L-04 percent bounds
/// @notice Unit and fuzz coverage for `maxFreePerBatch`, the overflow-driven discount boost,
///         `quotedBoost`, `previewBoost`, `boostDonationSafe` and the `paid >= 1` guarantee.
///         Mocks only (P0 = 10e18, growth 1 bp, tin 0 unless set). The fork gas boundary lives in
///         `test/fork/BatchNFTMinterNudgeDiscountGas.t.sol`.
contract BatchNFTMinterNudgeDiscountBoostTest is NudgeDiscountFixture {
    event MaxFreePerBatchSet(uint256 cap);
    event OverflowNFTsPerBoostPointSet(uint256 overflowNFTsPerBoostPoint);
    event MaxBoostSet(uint8 maxBoost);
    event TempDiscountApplied(uint256 overflowFree, uint8 boost, uint8 effectivePercent);
    event BatchMinted(
        address indexed recipient,
        uint256 free,
        uint256 paid,
        uint256 paidCost,
        uint256 potReservedUSDC,
        uint256 owedAdded
    );

    /// @dev USDC (6dp) that is worth exactly one P0 at tin 0.
    uint256 internal constant P0_USDC = P0 / CONV;

    // ---- helpers ----

    function _cfg(uint256 cap, uint256 perPoint, uint8 maxBoost_) internal {
        vm.startPrank(owner);
        batch.setMaxFreePerBatch(cap);
        batch.setOverflowNFTsPerBoostPoint(perPoint);
        batch.setMaxBoost(maxBoost_);
        vm.stopPrank();
    }

    function _boost() internal view returns (uint256 overflowFree, uint8 boost, uint8 eff, uint256 reserved) {
        return batch.previewBoost();
    }

    /// @dev `paidCost` of a full capped batch at effective percent `e` (fresh P0).
    function _paidCostAt(uint256 cap, uint256 e) internal pure returns (uint256) {
        return _ramp(P0, Math.ceilDiv(cap * 100, e) - cap);
    }

    /// @dev Largest single-point `paidCost` saving over every reachable effective percent.
    function _maxStepSaving(uint256 d, uint256 cap) internal pure returns (uint256 best) {
        for (uint256 e = d; e < 99; ++e) {
            uint256 s = _paidCostAt(cap, e) - _paidCostAt(cap, e + 1);
            if (s > best) best = s;
        }
    }

    /// @dev Smallest `overflowNFTsPerBoostPoint` that `boostDonationSafe()` accepts at the
    ///      current percent / cap. Leaves it set.
    function _minSafePerPoint() internal returns (uint256 pp) {
        for (pp = 1; pp < 1000; ++pp) {
            vm.prank(owner);
            batch.setOverflowNFTsPerBoostPoint(pp);
            if (batch.boostDonationSafe()) return pp;
        }
        revert("no safe perPoint");
    }

    function _batchQuoted(uint8 quoted) internal returns (uint256 totalPaid, uint256 free, uint256 paid) {
        (uint256 total, uint256 paidCost) = _previewTotal();
        vm.prank(caller);
        return batch.batchMint(total, quoted, recipient, paidCost, _bonusTokens(), _zeros());
    }

    // =====================================================================
    // 1. Defaults, setters, bounds
    // =====================================================================

    function test_Defaults() public {
        BatchNFTMinterNudgeDiscount fresh = new BatchNFTMinterNudgeDiscount(owner);
        assertEq(fresh.maxFreePerBatch(), 50, "cap default");
        assertEq(fresh.overflowNFTsPerBoostPoint(), 3, "perPoint default");
        assertEq(fresh.maxBoost(), 0, "boost ships disabled");
        assertEq(fresh.MIN_DISCOUNT_PERCENT(), 50);
        assertEq(fresh.MAX_DISCOUNT_PERCENT(), 99);
        // The fixture shares the defaults: the shipped parameters pass the donation constraint.
        assertTrue(batch.boostDonationSafe(), "defaults are donation-safe at d=50, cap 50");
    }

    function test_Setters_eventsAndStore() public {
        vm.startPrank(owner);
        vm.expectEmit(address(batch));
        emit MaxFreePerBatchSet(7);
        batch.setMaxFreePerBatch(7);
        vm.expectEmit(address(batch));
        emit OverflowNFTsPerBoostPointSet(4);
        batch.setOverflowNFTsPerBoostPoint(4);
        vm.expectEmit(address(batch));
        emit MaxBoostSet(49);
        batch.setMaxBoost(49);
        vm.stopPrank();
        assertEq(batch.maxFreePerBatch(), 7);
        assertEq(batch.overflowNFTsPerBoostPoint(), 4);
        assertEq(batch.maxBoost(), 49);
    }

    function test_Setters_revertOnBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroCap.selector);
        batch.setMaxFreePerBatch(0);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroBoostDivisor.selector);
        batch.setOverflowNFTsPerBoostPoint(0);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BoostTooHigh.selector, 50));
        batch.setMaxBoost(50);
        batch.setMaxBoost(0);
        vm.stopPrank();
    }

    function test_Setters_onlyOwner() public {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
        vm.startPrank(caller);
        vm.expectRevert(err);
        batch.setMaxFreePerBatch(10);
        vm.expectRevert(err);
        batch.setOverflowNFTsPerBoostPoint(10);
        vm.expectRevert(err);
        batch.setMaxBoost(10);
        vm.stopPrank();
    }

    // =====================================================================
    // 2. The cap leaves the excess (M-01)
    // =====================================================================

    function test_Cap_potAt3xCap_reservesOnlyCapAndLeavesRemainderRescuable() public {
        uint256 cap = 5;
        _cfg(cap, 3, 0);
        uint256 pot = 3 * cap * P0_USDC; // 150 USDC
        _fundPot(pot);

        (uint256 overflowFree, uint8 boost,, uint256 reserved) = _boost();
        assertEq(overflowFree, 2 * cap);
        assertEq(boost, 0, "maxBoost 0: no boost");
        assertEq(reserved, cap * P0_USDC, "reserve backs exactly cap * P0");

        (, uint256 free, uint256 paid) = _batch();
        assertEq(free, cap, "free is capped");
        assertEq(paid, cap, "d=50: paid == free");
        assertEq(batch.pendingBuyUSDC(), cap * P0_USDC, "only the capped part is reserved");
        assertEq(batch.availablePotUSDC(), pot - cap * P0_USDC, "remainder stays unreserved pot");

        // The remainder is rescuable; one wei more is not.
        uint256 remainder = batch.availablePotUSDC();
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.Rescue__ReservedFunds.selector, remainder + 1, remainder)
        );
        batch.rescueERC20(IERC20(address(usdc)), owner, remainder + 1);
        batch.rescueERC20(IERC20(address(usdc)), owner, remainder);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(batch)), batch.pendingBuyUSDC(), "only the reserve is left");
    }

    function test_Cap_reserveRoundsUpButNeverExceedsPot_withTin() public {
        psm.setTin(0.0137e18);
        uint256 cap = 5;
        _cfg(cap, 3, 0);
        uint256 pot = 3 * cap * P0_USDC + 123_457; // an awkward amount
        _fundPot(pot);
        (,,,,, uint256 potUSD,) = batch.previewBatch();
        uint256 expected = Math.mulDiv(pot, cap * P0, potUSD, Math.Rounding.Ceil);
        (,,, uint256 reserved) = _boost();
        assertEq(reserved, expected, "reserve == ceil(potUSDC * cap * P0 / potUSD)");
        assertLe(reserved, pot);
        // The reserve's own USD value covers the free NFTs it backs (rounded in the protocol's favour)
        // to within the PSM's floor on a single USDC unit.
        uint256 gross = reserved * CONV;
        assertGe(gross - (gross * 0.0137e18) / 1e18 + CONV, cap * P0);
        _batch();
        assertEq(batch.pendingBuyUSDC(), expected);
    }

    function testFuzz_Cap_reserveBounded(uint256 pot, uint256 cap, uint256 tin) public {
        cap = bound(cap, 1, 60);
        pot = bound(pot, P0_USDC, 5_000e6);
        tin = bound(tin, 0, 0.05e18);
        psm.setTin(tin);
        _cfg(cap, 3, 0);
        _fundPot(pot);
        (uint256 free,,,,, uint256 potUSD,) = batch.previewBatch();
        if (free == 0) return;
        (,,, uint256 reserved) = _boost();
        assertLe(reserved, pot, "reserve <= pot");
        assertLe(free, cap, "free <= cap");
        if (potUSD / P0 <= cap) assertEq(reserved, pot, "at or below the cap the whole pot is reserved");
        _batch();
        assertEq(batch.pendingBuyUSDC(), reserved, "tx reserve == preview reserve");
        assertEq(batch.availablePotUSDC(), pot - reserved);
    }

    // =====================================================================
    // 3. Boost maths
    // =====================================================================

    function test_Boost_zeroWithoutOverflow() public {
        _cfg(10, 1, 49);
        _fundPot(10 * P0_USDC); // exactly at the cap
        (uint256 overflowFree, uint8 boost, uint8 eff,) = _boost();
        assertEq(overflowFree, 0);
        assertEq(boost, 0);
        assertEq(eff, 50);
    }

    function test_Boost_monotoneStepsAndSaturates() public {
        uint256 cap = 10;
        uint256 pp = 3;
        uint8 mb = 7;
        _cfg(cap, pp, mb);
        _fundPot(cap * P0_USDC);
        uint256 last;
        for (uint256 o = 0; o <= uint256(mb) * pp + 10; ++o) {
            (uint256 overflowFree, uint8 boost, uint8 eff,) = _boost();
            assertEq(overflowFree, o, "overflow tracks the pot");
            uint256 expected = Math.min(o / pp, mb);
            assertEq(boost, expected, "boost = min(maxBoost, overflow / perPoint)");
            assertGe(boost, last, "monotone in overflow");
            assertLe(boost, mb, "saturates at maxBoost");
            assertEq(eff, 50 + boost);
            last = boost;
            _fundPot(P0_USDC);
        }
        assertEq(last, mb, "saturated");
    }

    function test_Boost_effectiveClampedAt99_paidStillOne() public {
        _setDiscount(80);
        _cfg(10, 1, 49);
        _fundPot(200 * P0_USDC); // overflow 190 -> live 49 -> 80 + 49 clamped
        (, uint8 boost, uint8 eff,) = _boost();
        assertEq(boost, 49);
        assertEq(eff, 99, "clamped at MAX_DISCOUNT_PERCENT");
        (uint256 free, uint256 total, uint256 paid,,,,) = batch.previewBatch();
        assertEq(free, 10);
        assertEq(total, 11, "ceil(1000 / 99) = 11");
        assertEq(paid, 1);
    }

    struct Expect {
        uint256 d;
        uint256 cap;
        uint256 pp;
        uint256 maxB;
        uint256 pot;
    }

    function testFuzz_Boost_mathsMatchSpec(uint256 dSeed, uint256 cap, uint256 pp, uint256 mb, uint256 pot) public {
        Expect memory x;
        x.d = bound(dSeed, 50, 99);
        x.cap = bound(cap, 1, 100);
        x.pp = bound(pp, 1, 10);
        x.maxB = bound(mb, 0, 49);
        x.pot = bound(pot, 0, 20_000e6);
        _setDiscount(uint8(x.d));
        _cfg(x.cap, x.pp, uint8(x.maxB));
        _fundPot(x.pot);
        _checkMaths(x);
    }

    function _checkMaths(Expect memory x) internal view {
        (uint256 free, uint256 total, uint256 paid,,, uint256 potUSD,) = batch.previewBatch();
        uint256 potFree = potUSD / P0;
        if (potFree == 0) {
            assertEq(free, 0);
            return;
        }
        uint256 expO = potFree > x.cap ? potFree - x.cap : 0;
        (uint256 overflowFree, uint8 boost, uint8 eff, uint256 reserved) = batch.previewBoost();
        assertEq(overflowFree, expO, "overflow");
        assertEq(boost, Math.min(x.maxB, expO / x.pp), "boost");
        assertLe(boost, x.maxB);
        assertEq(eff, Math.min(x.d + boost, 99), "effective");
        assertLe(eff, 99, "effective <= 99");
        assertEq(free, Math.min(potFree, x.cap), "free");
        assertEq(total, Math.ceilDiv(free * 100, eff), "total");
        assertGe(paid, 1, "paid >= 1 always");
        if (expO == 0) assertEq(reserved, x.pot);
        else assertLt(reserved, x.pot);
    }

    // =====================================================================
    // 4. Drain: the boost falls claim by claim, reaching 0 at the cap
    // =====================================================================

    function test_Drain_boostFallsToZero() public {
        uint256 cap = 10;
        _cfg(cap, 2, 30);
        _fundPot(70 * P0_USDC); // potFree 70, overflow 60, boost 30
        (, uint8 boost,,) = _boost();
        assertEq(boost, 30);

        uint256 prev = type(uint256).max;
        uint256 claims;
        while (true) {
            (uint256 overflowFree, uint8 b,,) = _boost();
            if (prev != type(uint256).max && prev != 0) assertLt(b, prev, "boost strictly falls while > 0");
            prev = b;
            (,, uint256 paid) = _batchQuoted(b);
            assertGe(paid, 1);
            ++claims;
            if (overflowFree == 0) break; // that claim consumed a pot at or below the cap
            assertLt(claims, 20, "drains in a bounded number of claims");
        }
        assertEq(prev, 0, "boost reaches 0 once the pot is at or below the cap");
        (uint256 o, uint8 bAfter,,) = _boost();
        assertEq(o, 0);
        assertEq(bAfter, 0);
    }

    // =====================================================================
    // 5. View == tx, including a pending stream
    // =====================================================================

    function _streamSetup() internal returns (NudgeStreamer streamer) {
        streamer = new NudgeStreamer(owner);
        vm.startPrank(owner);
        batch.setNudgeStreamer(address(streamer));
        streamer.registerStream(address(batch), address(usdc), 10 days);
        vm.stopPrank();
        address donor = makeAddr("donor");
        usdc.mint(donor, 10_000e6);
        vm.startPrank(donor);
        usdc.approve(address(streamer), type(uint256).max);
        streamer.collectNudge(address(batch), address(usdc), 2_000e6);
        vm.stopPrank();
    }

    function test_ViewEqualsTx_withPendingStream() public {
        NudgeStreamer streamer = _streamSetup();
        _cfg(50, 3, 20);
        vm.warp(block.timestamp + 5 days);
        assertGt(streamer.pendingStream(address(batch), address(usdc)), 0, "the stream is pending");
        assertEq(usdc.balanceOf(address(batch)), 0, "nothing has landed: the preview must add the stream");

        (uint256 free, uint256 total, uint256 paid, uint256 paidCost, uint256 owed,,) = batch.previewBatch();
        (uint256 overflowFree, uint8 boost, uint8 eff, uint256 reserved) = _boost();
        // ~1,000 USDC streamed (~100 P0; the streamer floors a few wei): overflow 49 or 50.
        assertGe(overflowFree, 49);
        assertLe(overflowFree, 50);
        assertEq(boost, overflowFree / 3);
        assertEq(eff, 50 + boost);

        vm.expectEmit(address(batch));
        emit BatchMinted(recipient, free, paid, paidCost, reserved, owed);
        vm.expectEmit(address(batch));
        emit TempDiscountApplied(overflowFree, boost, eff);
        vm.prank(caller);
        (uint256 totalPaid, uint256 f, uint256 p) =
            batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(f, free);
        assertEq(p, paid);
        assertEq(f + p, total);
        assertEq(totalPaid, paidCost);
        assertEq(batch.pendingBuyUSDC(), reserved, "tx reserve == preview reserve");
        assertEq(batch.pendingStakerPhUSD(), owed);
    }

    // =====================================================================
    // 6. Quoted boost
    // =====================================================================

    /// @dev Overflow 50 at cap 50, perPoint 3, maxBoost 20: live boost 16, effective 66.
    function _quotedSetup() internal returns (uint256 total, uint256 paidCost, uint8 boost) {
        _cfg(50, 3, 20);
        _fundPot(100 * P0_USDC);
        (total, paidCost) = _previewTotal();
        (, boost,,) = _boost();
        assertEq(boost, 16);
    }

    function test_Quoted_streamInflowAfterPreview_stillSucceedsAtQuote() public {
        NudgeStreamer streamer = _streamSetup();
        (uint256 total, uint256 paidCost, uint8 boost) = _quotedSetup();
        vm.warp(block.timestamp + 5 days); // ~1,000 USDC more streams in: the live boost rises
        assertGt(streamer.pendingStream(address(batch), address(usdc)), 0);
        (uint256 overflowNow, uint8 liveNow,,) = _boost();
        assertGt(liveNow, boost, "the live boost rose in flight");

        vm.expectEmit(address(batch));
        emit TempDiscountApplied(overflowNow, boost, 66); // the flushed overflow, the QUOTED terms
        vm.prank(caller);
        (uint256 totalPaid, uint256 free, uint256 paid) =
            batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(free + paid, total, "exactly the previewed batch");
        assertEq(totalPaid, paidCost);
    }

    function test_Quoted_frontRunningClaim_reverts() public {
        (uint256 total, uint256 paidCost, uint8 boost) = _quotedSetup();
        // A front-runner takes a batch at the same live terms first.
        address frontRunner = makeAddr("frontRunner");
        usds.mint(frontRunner, paidCost);
        vm.startPrank(frontRunner);
        usds.approve(address(batch), type(uint256).max);
        batch.batchMint(total, boost, frontRunner, paidCost, _bonusTokens(), _zeros());
        vm.stopPrank();

        (, uint8 live,,) = _boost();
        assertLt(live, boost);
        uint256 callerBefore = usds.balanceOf(caller);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector, boost, live)
        );
        batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(usds.balanceOf(caller), callerBefore, "nothing moved");
    }

    function test_Quoted_ownerRescue_reverts() public {
        (uint256 total, uint256 paidCost, uint8 boost) = _quotedSetup();
        vm.prank(owner);
        batch.rescueERC20(IERC20(address(usdc)), owner, 40 * P0_USDC); // overflow 50 -> 10: live 3
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector, boost, 3)
        );
        batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
    }

    function test_Quoted_p0Rise_reverts() public {
        (uint256 total, uint256 paidCost, uint8 boost) = _quotedSetup();
        // Stands in for a run of direct NFTMinterV2 mints, each of which ramps the price.
        minter.setConfig(IDX, 12e18, GROWTH_BPS); // potFree 1000/12 = 83, overflow 33, live 11
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector, boost, 11)
        );
        batch.batchMint(total, boost, recipient, paidCost, _bonusTokens(), _zeros());
    }

    function test_Quoted_belowLive_succeedsAtQuotedTerms() public {
        (,, uint8 live) = _quotedSetup();
        uint8 quoted = 5;
        uint256 total = Math.ceilDiv(50 * 100, 50 + quoted); // 91
        uint256 cost = _ramp(P0, total - 50);
        vm.expectEmit(address(batch));
        emit TempDiscountApplied(50, quoted, 55);
        vm.prank(caller);
        (uint256 totalPaid, uint256 free, uint256 paid) =
            batch.batchMint(total, quoted, recipient, cost, _bonusTokens(), _zeros());
        assertEq(free, 50);
        assertEq(paid, total - 50);
        assertEq(totalPaid, cost);
        assertLt(quoted, live);
    }

    function test_Quoted_zeroWithLiveBoost_succeedsWithoutEvent() public {
        _quotedSetup();
        uint256 total = 100; // undiscounted-by-boost terms: ceil(5000 / 50)
        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(total, 0, recipient, _ramp(P0, 50), _bonusTokens(), _zeros());
        _assertNoTempDiscount();
    }

    function test_Quoted_boostCheckedBeforeTotalMismatch() public {
        _cfg(50, 3, 20);
        _fundPot(100 * P0_USDC);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector, 17, 16)
        );
        batch.batchMint(12345, 17, recipient, type(uint256).max, _bonusTokens(), _zeros()); // total is wrong too
    }

    // =====================================================================
    // 7. Donation constraint (Safeguard 4)
    // =====================================================================

    function test_BoostDonationSafe_knownConfigs() public {
        _cfg(50, 2, 49);
        assertFalse(batch.boostDonationSafe(), "d=50 cap=50 perPoint=2 is unsafe");
        vm.prank(owner);
        batch.setOverflowNFTsPerBoostPoint(3);
        assertTrue(batch.boostDonationSafe(), "perPoint=3 is safe");

        vm.prank(owner);
        batch.setMaxFreePerBatch(25);
        vm.prank(owner);
        batch.setOverflowNFTsPerBoostPoint(1);
        assertFalse(batch.boostDonationSafe(), "cap 25 at d=50 needs more than 1");
        vm.prank(owner);
        batch.setOverflowNFTsPerBoostPoint(2);
        assertTrue(batch.boostDonationSafe());

        _setDiscount(75);
        vm.startPrank(owner);
        batch.setMaxFreePerBatch(50);
        batch.setOverflowNFTsPerBoostPoint(1);
        vm.stopPrank();
        assertTrue(batch.boostDonationSafe(), "cap 50 at d=75 needs 1+");

        _setDiscount(0);
        assertTrue(batch.boostDonationSafe(), "disabled: nothing to buy");
        _setDiscount(50);
        vm.prank(owner);
        batch.setDispatcherIndex(0);
        assertFalse(batch.boostDonationSafe(), "unconfigured minter: ramp unknowable -> unsafe");
    }

    /// @dev Over the grid d in {50, 75, 99}, cap in {25, 50} and every accepted perPoint (the
    ///      minimum and minimum + 1): a donor's `paidCost` saving is below their donation plus
    ///      one step's saving (the floored-step residual: a tiny donation just below a step
    ///      boundary buys a whole point early, which under P-006 is opportunity cost).
    function testFuzz_Donation_neverProfitable(
        uint256 gridSeed,
        bool plusOne,
        uint256 startOverflow,
        uint256 frac,
        uint256 donation
    ) public {
        uint8[3] memory ds = [uint8(50), 75, 99];
        uint256[2] memory caps = [uint256(25), 50];
        uint8 d = ds[gridSeed % 3];
        uint256 cap = caps[(gridSeed / 3) % 2];
        _setDiscount(d);
        vm.startPrank(owner);
        batch.setMaxFreePerBatch(cap);
        batch.setMaxBoost(49);
        vm.stopPrank();
        uint256 pp = _minSafePerPoint() + (plusOne ? 1 : 0);
        vm.prank(owner);
        batch.setOverflowNFTsPerBoostPoint(pp);
        assertTrue(batch.boostDonationSafe());

        startOverflow = bound(startOverflow, 0, 50 * pp);
        frac = bound(frac, 0, P0_USDC - 1);
        donation = bound(donation, 1, 60 * pp * P0_USDC);
        _fundPot((cap + startOverflow) * P0_USDC + frac);
        (,,, uint256 costBefore,,,) = batch.previewBatch();
        _fundPot(donation); // the donor tops up the pot, then claims the batch themselves
        (,,, uint256 costAfter,,,) = batch.previewBatch();
        uint256 saving = costBefore > costAfter ? costBefore - costAfter : 0;

        assertLt(saving, donation * CONV + _maxStepSaving(d, cap), "donation is not profitable");
    }

    /// @dev Amortised form: across the whole reachable boost range, the average saving per point
    ///      is below the overflow a point costs (`perPoint * P0`).
    function test_Donation_amortisedPerPointSavingBelowCost() public {
        uint8[3] memory ds = [uint8(50), 75, 99];
        uint256[2] memory caps = [uint256(25), 50];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 2; ++j) {
                _setDiscount(ds[i]);
                vm.prank(owner);
                batch.setMaxFreePerBatch(caps[j]);
                uint256 pp = _minSafePerPoint();
                uint256 points = Math.min(49, 99 - uint256(ds[i]));
                if (points == 0) continue; // d = 99: the clamp leaves no boost to buy
                uint256 saving = _paidCostAt(caps[j], ds[i]) - _paidCostAt(caps[j], ds[i] + points);
                assertLt(saving, points * pp * P0, "amortised saving per point < perPoint * P0");
            }
        }
    }

    // =====================================================================
    // 8. Pause path (L-04)
    // =====================================================================

    function _maxBoostSetup() internal returns (uint256 total, uint256 paidCost) {
        _setDiscount(99);
        _cfg(10, 1, 49);
        _fundPot(200 * P0_USDC);
        (, uint8 boost, uint8 eff,) = _boost();
        assertEq(boost, 49);
        assertEq(eff, 99);
        (total, paidCost) = _previewTotal();
    }

    function test_Pause_minterPaused_haltsMaxBoostedBatch() public {
        (uint256 total, uint256 paidCost) = _maxBoostSetup();
        minter.setPaused(true);
        vm.prank(caller);
        vm.expectRevert(MockITokenMinterV2.MockITokenMinterV2__Paused.selector);
        batch.batchMint(total, 49, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(minter.mintForCallCount(), 0, "no free mint against a paused minter");

        minter.setPaused(false);
        vm.prank(caller);
        (,, uint256 paid) = batch.batchMint(total, 49, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(paid, 1);
    }

    function test_Pause_indexDisabled_haltsMaxBoostedBatch() public {
        (uint256 total, uint256 paidCost) = _maxBoostSetup();
        minter.setDispatcherDisabled(IDX, true);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MockITokenMinterV2.MockITokenMinterV2__Disabled.selector, IDX));
        batch.batchMint(total, 49, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(minter.mintForCallCount(), 0, "no free mint against a disabled index");
    }

    // =====================================================================
    // 9. TempDiscountApplied iff boost != 0
    // =====================================================================

    function _assertNoTempDiscount() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = TempDiscountApplied.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(batch)) {
                assertTrue(logs[i].topics[0] != topic, "unexpected TempDiscountApplied");
            }
        }
    }

    function test_Event_notEmittedWithoutBoost() public {
        _cfg(10, 1, 0); // overflow but maxBoost 0
        _fundPot(30 * P0_USDC);
        vm.recordLogs();
        _batch();
        _assertNoTempDiscount();
        uint256 leftover = batch.availablePotUSDC();
        vm.prank(owner);
        batch.rescueERC20(IERC20(address(usdc)), owner, leftover);

        _cfg(10, 1, 49); // boost enabled but no overflow
        _fundPot(5 * P0_USDC);
        vm.recordLogs();
        _batch();
        _assertNoTempDiscount();
    }

    function test_Event_emittedWithBoost_correctFields() public {
        _cfg(10, 4, 49);
        _fundPot(31 * P0_USDC); // overflow 21 -> boost 5
        vm.expectEmit(address(batch));
        emit TempDiscountApplied(21, 5, 55);
        _batch();
    }

    // =====================================================================
    // 10. previewBatch.nextStepUSDC above the cap; previewBoost misconfigured
    // =====================================================================

    function test_NextStepUSDC_aboveCap_meansOverflowPlusOne() public {
        _cfg(10, 1, 49);
        _fundPot(13 * P0_USDC + 4_000_000); // potFree 13.4 -> overflow 3
        (uint256 free,,,,,, uint256 step) = batch.previewBatch();
        (uint256 o,,,) = _boost();
        assertEq(free, 10);
        assertEq(o, 3);
        assertEq(step, 6_000_000, "USDC until overflow + 1");
        _fundPot(step - 1);
        (o,,,) = _boost();
        assertEq(o, 3);
        _fundPot(1);
        (free,,,,,,) = batch.previewBatch();
        (o,,,) = _boost();
        assertEq(o, 4, "overflow + 1");
        assertEq(free, 10, "free stays at the cap");
    }

    function test_PreviewBoost_misconfigured_returnsZeros() public {
        _cfg(10, 1, 49);
        vm.prank(owner);
        batch.setMintDebtHook(IMintDebtRatio(address(0)));
        _fundPot(100 * P0_USDC);
        (uint256 o, uint8 b, uint8 e, uint256 r) = _boost();
        assertEq(o, 0);
        assertEq(b, 0);
        assertEq(e, 0);
        assertEq(r, 0);
    }
}
