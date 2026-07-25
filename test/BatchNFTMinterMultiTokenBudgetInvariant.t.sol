// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stateful fuzz driver for `batchMint` under the hardest configuration
///         available: the derived payment token IS a whitelisted nudge token, so
///         the caller's budget, the standing pot and the payout all live in the
///         same asset and any accounting confusion between them is observable as
///         a balance error rather than hidden behind a second token.
///
/// @dev    The handler is the batch minter's OWNER as well as the batching
///         caller, so it can fuzz `nudgeSize` between calls the way a live owner
///         would. It records violations into sticky booleans rather than
///         asserting inline, so a single bad sequence cannot be masked by a later
///         good one, and Foundry reports the shrunk sequence against the
///         invariant rather than against a handler revert.
contract BudgetInvariantHandler is Test {
    BatchNFTMinterMultiToken public batch;
    MockITokenMinterV2 public minter;
    MockTokenDispatcherV2 public disp;
    MockERC1155 public nft;
    MockERC20 public payToken;
    MockERC20 public bootToken;

    address public constant RECIPIENT = address(0xBEEF);

    uint256 public constant DISPATCHER_INDEX = 7;
    uint256 public constant START_PRICE = 1_000 ether;
    uint256 public constant GROWTH_BPS = 250;

    // ---- ghost state ----

    uint256 public calls;
    uint256 public successes;
    uint256 public reverts;
    /// @dev Set false the first time `refund > paymentAmount` or `totalPaid`
    ///      disagrees with the refund actually delivered.
    bool public refundBoundHeld = true;
    /// @dev Set false the first time the pot moves by anything other than `0`
    ///      (non-qualifying) or `-P` (qualifying).
    bool public potIntegrityHeld = true;
    /// @dev Highest `nudgeSize` a qualifying batch was actually observed at, so
    ///      the invariant can prove the qualifying branch was exercised at all.
    uint256 public qualifyingBatches;
    uint256 public nonQualifyingBatches;

    constructor() {
        payToken = new MockERC20("PayToken", "PAY");
        bootToken = new MockERC20("BootToken", "BOOT");
        nft = new MockERC1155();
        minter = new MockITokenMinterV2();
        disp = new MockTokenDispatcherV2(address(bootToken));

        minter.setStakedToken(nft);
        minter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        minter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        minter.setDispatcher(DISPATCHER_INDEX, address(disp));

        // This handler is the owner.
        batch = new BatchNFTMinterMultiToken(address(this));
        batch.setTokenMinter(ITokenMinterV2(address(minter)));
        batch.setDispatcherIndex(DISPATCHER_INDEX);
        batch.setNudgeSize(5);
        batch.setNudgeTokenWhitelist(address(payToken), true);

        // Repoint: `payToken` is now BOTH the derived payment token and the sole
        // whitelisted nudge token.
        disp.setPrimeToken(address(payToken));
    }

    function _cost(uint256 count) internal view returns (uint256 total) {
        uint256 price = minter.getPrice(DISPATCHER_INDEX);
        for (uint256 i; i < count; ++i) {
            total += price;
            price = price + (price * GROWTH_BPS) / 10000;
        }
    }

    /// @notice The single fuzzed action: top the pot up by an arbitrary amount,
    ///         set an arbitrary `nudgeSize`, and batch an arbitrary `count`
    ///         against an arbitrary surplus (or shortfall).
    function batchMintFuzzed(uint256 countSeed, uint256 surplusSeed, uint256 nudgeSeed, uint256 potSeed) external {
        calls++;

        uint256 count = bound(countSeed, 1, 8);
        uint256 nudge = bound(nudgeSeed, 0, 10);
        // Deliberately allows a SHORTFALL as well as a surplus: `paymentAmount`
        // can land below the cumulative charge, which must revert rather than
        // draw on the pot.
        uint256 quoteDelta = bound(surplusSeed, 0, 8_000 ether);
        bool underQuote = surplusSeed % 4 == 0;
        uint256 potAdd = bound(potSeed, 0, 20_000 ether);

        batch.setNudgeSize(nudge);
        if (potAdd != 0) payToken.mint(address(batch), potAdd);

        uint256 pot = payToken.balanceOf(address(batch));
        uint256 cost = _cost(count);
        uint256 paymentAmount = underQuote ? (quoteDelta > cost ? 0 : cost - quoteDelta) : cost + quoteDelta;

        payToken.mint(address(this), paymentAmount);
        payToken.approve(address(batch), paymentAmount);

        uint256 recipientBefore = payToken.balanceOf(RECIPIENT);
        uint256 selfBefore = payToken.balanceOf(address(this));

        uint256[] memory mins = new uint256[](1);

        try batch.batchMint(count, RECIPIENT, paymentAmount, mins) returns (uint256 totalPaid) {
            successes++;

            uint256 refund = payToken.balanceOf(address(this)) + paymentAmount - selfBefore;
            uint256 paidOut = payToken.balanceOf(RECIPIENT) - recipientBefore;
            bool qualifies = nudge != 0 && count >= nudge;

            // --- refund bound ---
            if (refund > paymentAmount) refundBoundHeld = false;
            if (totalPaid != paymentAmount - refund) refundBoundHeld = false;

            // --- pot integrity: all-or-nothing, never partial ---
            if (paidOut != (qualifies ? pot : 0)) potIntegrityHeld = false;
            // The pot never shrinks by more than the payout. (It may GROW: an
            // unrefunded sub-threshold surplus stays behind and becomes pot.)
            if (payToken.balanceOf(address(batch)) + (qualifies ? pot : 0) < pot) potIntegrityHeld = false;

            if (qualifies) {
                qualifyingBatches++;
            } else {
                nonQualifyingBatches++;
            }
        } catch {
            reverts++;
            // A rejected batch must be atomic: the pot is exactly where it was.
            if (payToken.balanceOf(address(batch)) != pot) potIntegrityHeld = false;
            if (payToken.balanceOf(RECIPIENT) != recipientBefore) potIntegrityHeld = false;
        }
    }
}

/// @title `batchMint` budget invariants (plan §8.5 - §8.6)
///
/// Run-20 D-35 required these properties to be **established and tested**, not
/// shipped as an unvalidated patch. Story 029 makes them structural; this
/// harness pins them under fuzzed `count`, `paymentAmount`, `nudgeSize` and pot
/// size, in the configuration where the payment token and the reward token are
/// the same asset.
contract BatchNFTMinterMultiTokenBudgetInvariantTest is StdInvariant, Test {
    BudgetInvariantHandler internal handler;

    function setUp() public {
        handler = new BudgetInvariantHandler();

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BudgetInvariantHandler.batchMintFuzzed.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev §8.5. `refund <= paymentAmount`, always. This is the property whose
    ///      violation was `ycn19h1`: a refund of `P + (A - C) + D` against a
    ///      `paymentAmount` of one wei. It now holds by construction, because
    ///      `budget` starts at `paymentAmount` and only ever decreases — and
    ///      `totalPaid == paymentAmount - refund` is checked alongside it, so the
    ///      accounting cannot be satisfied by simply refunding nothing.
    function invariant_RefundNeverExceedsPaymentAmount() public view {
        assertTrue(
            handler.refundBoundHeld(),
            "refund exceeded paymentAmount (or totalPaid disagreed with it) for some fuzzed batch"
        );
    }

    /// @dev §8.6. The pot leaves all at once through a qualifying payout, or not
    ///      at all. Never partially, and never to `msg.sender`.
    function invariant_PotOnlyLeavesViaQualifyingPayout() public view {
        assertTrue(
            handler.potIntegrityHeld(),
            "the nudge pot moved by something other than 0 (non-qualifying) or -P (qualifying)"
        );
    }

    /// @dev Anti-vacuity. Both branches must actually have been exercised, or
    ///      the two invariants above are statements about nothing. Checked once
    ///      per run rather than per call, since a single call can only be one of
    ///      the two.
    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "TRIPWIRE: the handler was never called");
        assertGt(handler.successes(), 0, "TRIPWIRE: no batch ever succeeded");
        assertGt(handler.qualifyingBatches(), 0, "TRIPWIRE: the qualifying payout branch was never exercised");
        assertGt(handler.nonQualifyingBatches(), 0, "TRIPWIRE: the non-qualifying branch was never exercised");
        assertGt(
            handler.reverts(), 0, "TRIPWIRE: an under-quoted batch never reverted, so the budget bound was never hit"
        );
    }
}
