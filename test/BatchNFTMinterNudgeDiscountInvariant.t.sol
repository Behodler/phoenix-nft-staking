// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
///         deliberately stale — `expectedTotal`, under-quoted `maxPayment`, `discountPercent`,
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
    uint256 public buysWithBurn;
    uint256 public rallyCarryForwards;
    uint256 public buys;

    uint256 public owedAdded;
    uint256 public owedPaid;

    bool public refundBoundHeld = true;
    bool public buySplitHeld = true;

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
        // Weight towards realistic discounts; [0, 100] overall, 0 included.
        d = bound(d, 0, 100);
        if (d != 0 && d < 10) d += 10;
        vm.prank(owner);
        batch.setDiscountPercent(uint8(d));
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
        (, uint256 total,, uint256 paidCost,,,) = batch.previewBatch();

        uint256 expectedTotal = total == 0 ? 1 : total;
        if (staleSeed % 5 == 0) expectedTotal += 1; // deliberately stale

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
        try batch.batchMint(expectedTotal, recipient, maxPayment, mins) returns (uint256 totalPaid, uint256, uint256) {
            successfulBatches++;
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
/// forge-config: default.invariant.depth = 500
contract BatchNFTMinterNudgeDiscountInvariantTest is StdInvariant, NudgeDiscountFixture {
    NudgeDiscountHandler internal handler;
    NudgeStreamer internal streamer;

    function setUp() public override {
        super.setUp();
        streamer = new NudgeStreamer(owner);
        vm.startPrank(owner);
        batch.setNudgeStreamer(address(streamer));
        streamer.registerStream(address(batch), address(usdc), 10 days);
        vm.stopPrank();

        handler = new NudgeDiscountHandler(batch, streamer, usdc, usds, phUSD, psm, sUSDS, router, owner, buyer);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = NudgeDiscountHandler.topUpDirect.selector;
        selectors[1] = NudgeDiscountHandler.topUpStreamed.selector;
        selectors[2] = NudgeDiscountHandler.setDiscountPercent.selector;
        selectors[3] = NudgeDiscountHandler.setBurnPercent.selector;
        selectors[4] = NudgeDiscountHandler.setTin.selector;
        selectors[5] = NudgeDiscountHandler.reprice.selector;
        selectors[6] = NudgeDiscountHandler.batchMintFuzzed.selector;
        selectors[7] = NudgeDiscountHandler.buyPartial.selector;
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

    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "TRIPWIRE: handler never called");
        assertGt(handler.successfulBatches(), 0, "TRIPWIRE: no batch ever succeeded");
        assertGt(handler.noDiscountReverts(), 0, "TRIPWIRE: NoDiscountAvailable never hit");
        assertGt(handler.totalMismatchReverts(), 0, "TRIPWIRE: TotalMismatch never hit");
        assertGt(handler.buysWithBurn(), 0, "TRIPWIRE: no buy ever burned");
        assertGt(handler.rallyCarryForwards(), 0, "TRIPWIRE: no rally carry-forward");
    }
}
