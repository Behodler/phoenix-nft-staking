// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INFTMinterV2} from "yield-claim-nft/interfaces/INFTMinterV2.sol";

import {BatchNFTMinterNudgeDiscount} from "../src/BatchNFTMinterNudgeDiscount.sol";
import {NudgeStreamer} from "../src/NudgeStreamer.sol";
import {NudgeDiscountFixture} from "./BatchNFTMinterNudgeDiscount.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockSkyPSM} from "./mocks/MockSkyPSM.sol";
import {MockSUSDS} from "./mocks/MockSUSDS.sol";
import {MockBurnablePhUSD} from "./mocks/MockBurnablePhUSD.sol";
import {MockUniV2AmmRouter} from "./mocks/MockUniV2Amm.sol";

/// @notice Stateful fuzz driver for `BatchNFTMinterNudgeDiscount`, following the
///         `BudgetInvariantHandler` / `afterInvariant` tripwire pattern of
///         `BatchNFTMinterMultiTokenBudgetInvariant.t.sol`.
///
/// @dev    Fuzzes pot top-ups (direct and streamed), `batchMint` at a previewed — or
///         deliberately stale — `expectedTotal` and `quotedBoost`, under-quoted `maxPayment`,
///         `discountPercent`, the audit-27 cap / boost parameters,
///         `burnPercent`, PSM `tin`, AMM repricing, and partial `buyAndBurn`. Violations are
///         recorded in sticky booleans so a later good call cannot mask an earlier bad one.
contract NudgeDiscountHandler is Test {
    BatchNFTMinterNudgeDiscount public batch;
    NudgeStreamer public streamer;
    MockUSDC public usdc;
    MockERC20 public usds;
    MockBurnablePhUSD public phUSD;
    MockSkyPSM public psm;
    MockSUSDS public sUSDS;
    MockUniV2AmmRouter public router;

    address public owner;
    address public buyer;
    address public caller = address(0xCA11E5);
    address public recipient = address(0x5EC1);
    address public donor = address(0xD0D0);
    address public whale = address(0x3A1E);

    uint256 internal constant DUST = 1e6;

    // ---- ghost state ----
    uint256 public calls;
    uint256 public successfulBatches;
    uint256 public noDiscountReverts;
    uint256 public totalMismatchReverts;
    uint256 public boostNotAvailableReverts;
    uint256 public boostedBatches;
    uint256 public cappedBatches;
    uint256 public buysWithBurn;
    uint256 public rallyCarryForwards;
    uint256 public buys;

    uint256 public owedAdded;
    uint256 public owedPaid;

    bool public refundBoundHeld = true;
    bool public buySplitHeld = true;
    /// @dev audit-27: every successful batch had `1 <= paid`, `free <= cap`, and reserved at
    ///      most the live pot.
    bool public capAndPaidHeld = true;

    constructor(
        BatchNFTMinterNudgeDiscount batch_,
        NudgeStreamer streamer_,
        MockUSDC usdc_,
        MockERC20 usds_,
        MockBurnablePhUSD phUSD_,
        MockSkyPSM psm_,
        MockSUSDS sUSDS_,
        MockUniV2AmmRouter router_,
        address owner_,
        address buyer_
    ) {
        batch = batch_;
        streamer = streamer_;
        usdc = usdc_;
        usds = usds_;
        phUSD = phUSD_;
        psm = psm_;
        sUSDS = sUSDS_;
        router = router_;
        owner = owner_;
        buyer = buyer_;

        vm.prank(caller);
        usds.approve(address(batch), type(uint256).max);
        vm.startPrank(donor);
        usdc.approve(address(streamer), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- top-ups

    function topUpDirect(uint256 amount) external {
        calls++;
        amount = bound(amount, 0, 60e6);
        usdc.mint(address(batch), amount);
    }

    function topUpStreamed(uint256 amount, uint256 warpBy) external {
        calls++;
        amount = bound(amount, 1, 120e6);
        warpBy = bound(warpBy, 0, 5 days);
        usdc.mint(donor, amount);
        vm.prank(donor);
        streamer.collectNudge(address(batch), address(usdc), amount);
        vm.warp(block.timestamp + warpBy);
    }

    // ---------------------------------------------------------------- owner knobs

    function setDiscountPercent(uint256 d) external {
        calls++;
        // audit-27: the legal range is {0} ∪ [MIN_DISCOUNT_PERCENT, 99].
        d = bound(d, 0, 50);
        if (d != 0) d += 49;
        vm.prank(owner);
        batch.setDiscountPercent(uint8(d));
    }

    /// @dev audit-27: the owner's remedy for an overflowing pot — rescue some or all of the
    ///      UNRESERVED pot. Must never touch the reserve (`invariant_ReserveNeverExceedsBalance`).
    function rescueUnreserved(uint256 frac) external {
        calls++;
        uint256 unreserved = batch.availablePotUSDC();
        if (unreserved == 0) return;
        uint256 amount = bound(frac, 1, unreserved);
        vm.prank(owner);
        batch.rescueERC20(IERC20(address(usdc)), owner, amount);
    }

    function setMaxFreePerBatch(uint256 cap) external {
        calls++;
        vm.prank(owner);
        batch.setMaxFreePerBatch(bound(cap, 1, 60));
    }

    function setOverflowNFTsPerBoostPoint(uint256 perPoint) external {
        calls++;
        vm.prank(owner);
        batch.setOverflowNFTsPerBoostPoint(bound(perPoint, 1, 4));
    }

    function setMaxBoost(uint256 boost) external {
        calls++;
        vm.prank(owner);
        batch.setMaxBoost(uint8(bound(boost, 0, 49)));
    }

    function setBurnPercent(uint256 b) external {
        calls++;
        vm.prank(owner);
        batch.setBurnPercent(uint8(bound(b, 0, 100)));
    }

    function setTin(uint256 tin) external {
        calls++;
        psm.setTin(bound(tin, 0, 0.05e18));
    }

    function reprice(bool rally, uint256 amount) external {
        calls++;
        address[] memory path = new address[](2);
        if (rally) {
            amount = bound(amount, 1e18, 2_000_000e18);
            usds.mint(whale, amount);
            vm.startPrank(whale);
            usds.approve(address(sUSDS), amount);
            uint256 shares = sUSDS.deposit(amount, whale);
            IERC20(address(sUSDS)).approve(address(router), shares);
            path[0] = address(sUSDS);
            path[1] = address(phUSD);
            router.swapExactTokensForTokens(shares, 1, path, whale, block.timestamp);
            vm.stopPrank();
        } else {
            amount = bound(amount, 1e18, 2_000_000e18);
            phUSD.mint(whale, amount);
            vm.startPrank(whale);
            phUSD.approve(address(router), amount);
            path[0] = address(phUSD);
            path[1] = address(sUSDS);
            router.swapExactTokensForTokens(amount, 1, path, whale, block.timestamp);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- batch

    function batchMintFuzzed(uint256 staleSeed, uint256 quoteSeed) external {
        calls++;
        _doBatch(staleSeed, quoteSeed);
    }

    /// @dev audit-27 composite: push the pot `1..4` boost points past the cap, batch at the
    ///      live boost, then the owner rescues the unreserved leftover (the documented remedy).
    ///      Guarantees capped and boosted batches are reachable in every run without letting the
    ///      pot grow without bound (which would starve the `NoDiscountAvailable` path).
    function overflowBatch(uint256 extra, uint256 quoteSeed) external {
        calls++;
        (, uint256 p0,,) = INFTMinterV2(address(batch.tokenMinter())).configs(batch.dispatcherIndex());
        uint256 n = batch.maxFreePerBatch() + batch.overflowNFTsPerBoostPoint() * bound(extra, 1, 4);
        // +6% covers the fuzzed PSM tin (<= 5%).
        usdc.mint(address(batch), (n * p0 * 106) / 100 / 1e12 + 1);
        // staleSeed 2: neither stale nor over-quoted; 1: over-quoted (live + 1).
        _doBatch(quoteSeed % 3 == 0 ? 1 : 2, quoteSeed);
        uint256 leftover = batch.availablePotUSDC();
        if (leftover != 0) {
            vm.prank(owner);
            batch.rescueERC20(IERC20(address(usdc)), owner, leftover);
        }
    }

    function _doBatch(uint256 staleSeed, uint256 quoteSeed) internal {
        (, uint256 total,, uint256 paidCost,,,) = batch.previewBatch();
        uint8 liveBoost;
        (, liveBoost,, _previewReserve) = batch.previewBoost();
        _potBefore = batch.availablePotUSDC() + streamer.pendingStream(address(batch), address(usdc));
        _reserveBefore = batch.pendingBuyUSDC();

        uint256 expectedTotal = total == 0 ? 1 : total;
        if (staleSeed % 5 == 0) expectedTotal += 1; // deliberately stale
        uint8 quotedBoost = liveBoost;
        if (staleSeed % 7 == 1) quotedBoost = liveBoost + 1; // deliberately above live

        uint256 maxPayment;
        uint256 mode = quoteSeed % 4;
        if (mode == 0) maxPayment = paidCost;
        else if (mode == 1) maxPayment = paidCost + DUST + (quoteSeed % 1000e18);
        else if (mode == 2) maxPayment = paidCost == 0 ? 0 : paidCost - 1; // under-quoted
        else maxPayment = paidCost + 2 * DUST;

        usds.mint(caller, maxPayment);
        uint256 callerUsdsBefore = usds.balanceOf(caller);
        uint256 owedBefore = batch.pendingStakerPhUSD();

        uint256[] memory mins = new uint256[](batch.getBonusTokens().length);
        vm.prank(caller);
        try batch.batchMint(expectedTotal, quotedBoost, recipient, maxPayment, mins) returns (
            uint256 totalPaid, uint256 free, uint256 paid
        ) {
            successfulBatches++;
            if (quotedBoost != 0) boostedBatches++;
            _checkCap(free, paid);
            owedAdded += batch.pendingStakerPhUSD() - owedBefore;
            uint256 spent = callerUsdsBefore - usds.balanceOf(caller);
            uint256 refund = maxPayment - spent;
            if (refund > maxPayment || spent != totalPaid || totalPaid != paidCost) {
                refundBoundHeld = false;
            }
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel == BatchNFTMinterNudgeDiscount.BatchMint__NoDiscountAvailable.selector) noDiscountReverts++;
            else if (sel == BatchNFTMinterNudgeDiscount.BatchMint__TotalMismatch.selector) totalMismatchReverts++;
            else if (sel == BatchNFTMinterNudgeDiscount.BatchMint__BoostNotAvailable.selector) boostNotAvailableReverts++;
        }
    }

    // Pre-batch snapshots, in storage for the legacy code generator's stack limit.
    uint256 internal _previewReserve;
    uint256 internal _potBefore;
    uint256 internal _reserveBefore;

    function _checkCap(uint256 free, uint256 paid) internal {
        uint256 reserved = batch.pendingBuyUSDC() - _reserveBefore;
        uint256 cap = batch.maxFreePerBatch();
        if (free == cap && reserved < _potBefore) cappedBatches++;
        if (paid == 0 || free > cap || reserved > _potBefore || reserved != _previewReserve) {
            capAndPaidHeld = false;
        }
    }

    // ---------------------------------------------------------------- buy

    function buyPartial(uint256 frac) external {
        calls++;
        uint256 reserve = batch.pendingBuyUSDC();
        if (reserve == 0) return;
        uint256 usdcIn = bound(frac, 1, reserve);
        uint256 owedBefore = batch.pendingStakerPhUSD();
        uint256 stakerBefore = phUSD.balanceOf(batch.nftStaker());
        uint256 supplyBefore = phUSD.totalSupply();
        uint256 heldBefore = phUSD.balanceOf(address(batch));

        vm.prank(buyer);
        try batch.buyAndBurn(usdcIn, 1, block.timestamp) returns (uint256 out, uint256 toStaker, uint256 burned) {
            buys++;
            uint256 paidOwed = owedBefore - batch.pendingStakerPhUSD();
            owedPaid += paidOwed;
            if (
                out != toStaker + burned || phUSD.balanceOf(batch.nftStaker()) - stakerBefore != toStaker
                    || supplyBefore - phUSD.totalSupply() != burned || phUSD.balanceOf(address(batch)) != heldBefore
            ) buySplitHeld = false;
            if (burned > 0) buysWithBurn++;
            if (out < owedBefore) rallyCarryForwards++;
        } catch {
            // A buy that rounds to zero phUSD out (dust usdcIn) reverts in the router: fine.
        }
    }
}

/// @notice Invariant suite over `NudgeDiscountHandler`.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 850
contract BatchNFTMinterNudgeDiscountInvariantTest is StdInvariant, NudgeDiscountFixture {
    NudgeDiscountHandler internal handler;
    NudgeStreamer internal streamer;

    function setUp() public override {
        super.setUp();
        streamer = new NudgeStreamer(owner);
        vm.startPrank(owner);
        batch.setNudgeStreamer(address(streamer));
        streamer.registerStream(address(batch), address(usdc), 10 days);
        // audit-27: start every run with a live boost (the handler then re-fuzzes the knobs).
        batch.setOverflowNFTsPerBoostPoint(1);
        batch.setMaxBoost(20);
        vm.stopPrank();

        handler = new NudgeDiscountHandler(batch, streamer, usdc, usds, phUSD, psm, sUSDS, router, owner, buyer);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = NudgeDiscountHandler.topUpDirect.selector;
        selectors[1] = NudgeDiscountHandler.topUpStreamed.selector;
        selectors[2] = NudgeDiscountHandler.setDiscountPercent.selector;
        selectors[3] = NudgeDiscountHandler.setBurnPercent.selector;
        selectors[4] = NudgeDiscountHandler.setTin.selector;
        selectors[5] = NudgeDiscountHandler.reprice.selector;
        selectors[6] = NudgeDiscountHandler.batchMintFuzzed.selector;
        selectors[7] = NudgeDiscountHandler.buyPartial.selector;
        selectors[8] = NudgeDiscountHandler.setMaxFreePerBatch.selector;
        selectors[9] = NudgeDiscountHandler.setOverflowNFTsPerBoostPoint.selector;
        selectors[10] = NudgeDiscountHandler.setMaxBoost.selector;
        selectors[11] = NudgeDiscountHandler.rescueUnreserved.selector;
        selectors[12] = NudgeDiscountHandler.overflowBatch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The user never receives the discount token.
    function invariant_UserNeverReceivesDiscountToken() public view {
        assertEq(usdc.balanceOf(handler.caller()), 0, "caller received USDC");
        assertEq(usdc.balanceOf(handler.recipient()), 0, "recipient received USDC");
    }

    /// @dev The reserve never exceeds the balance.
    function invariant_ReserveNeverExceedsBalance() public view {
        assertLe(batch.pendingBuyUSDC(), usdc.balanceOf(address(batch)), "reserve > USDC balance");
    }

    /// @dev phUSD out == staker + burn exactly, on every buy; no bought phUSD stays behind.
    function invariant_BuySplitExact() public view {
        assertTrue(handler.buySplitHeld(), "a buy's phUSD out != toStaker + burned, or phUSD stayed behind");
    }

    /// @dev Refund <= pulled budget, and totalPaid == paidCost on every successful batch.
    function invariant_RefundBound() public view {
        assertTrue(handler.refundBoundHeld(), "refund exceeded budget, or totalPaid != paidCost");
    }

    /// @dev Owed is conserved: cumulative owed added == cumulative owed paid + carried.
    function invariant_OwedConserved() public view {
        assertEq(handler.owedAdded(), handler.owedPaid() + batch.pendingStakerPhUSD(), "owed not conserved");
    }

    /// @dev audit-27: `paid >= 1`, `free <= cap`, reserve <= live pot and == the preview's reserve.
    function invariant_CapAndPaidFloor() public view {
        assertTrue(handler.capAndPaidHeld(), "paid == 0, free > cap, or reserve exceeded the pot / preview");
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "TRIPWIRE: handler never called");
        assertGt(handler.successfulBatches(), 0, "TRIPWIRE: no batch ever succeeded");
        assertGt(handler.noDiscountReverts(), 0, "TRIPWIRE: NoDiscountAvailable never hit");
        assertGt(handler.totalMismatchReverts(), 0, "TRIPWIRE: TotalMismatch never hit");
        assertGt(handler.boostNotAvailableReverts(), 0, "TRIPWIRE: BoostNotAvailable never hit");
        assertGt(handler.boostedBatches(), 0, "TRIPWIRE: no boosted batch");
        assertGt(handler.cappedBatches(), 0, "TRIPWIRE: no capped batch");
        assertGt(handler.buysWithBurn(), 0, "TRIPWIRE: no buy ever burned");
        assertGt(handler.rallyCarryForwards(), 0, "TRIPWIRE: no rally carry-forward");
    }
}
