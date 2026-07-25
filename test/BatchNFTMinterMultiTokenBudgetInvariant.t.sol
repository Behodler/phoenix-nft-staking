// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";

/// @dev Minting faculty shared by every mock ERC20 here, so one handler can be
///      driven with a well-behaved or a fee-on-transfer payment token.
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @notice Stateful fuzz driver for `batchMint` under the hardest configuration
///         available: the derived payment token IS a whitelisted nudge token, so
///         the caller's budget, the standing pot and the payout all live in the
///         same asset and any accounting confusion between them is observable as
///         a balance error rather than hidden behind a second token.
///
/// @dev    Parameterised by the payment token's `feeBasisPoints` and by a
///         per-mint donation, so the same driver covers the well-behaved case
///         and the two things the original harness could not see:
///
///           - `feeBps != 0` — the token credits less than `paymentAmount`, the
///             case that made the pot-integrity claim conditional until `budget`
///             became a measured quantity;
///           - `donationPerMint != 0` — the donate-forward pool `D` arrives
///             DURING the mint loop, so the run distinguishes a budget tracked
///             per-price from one bracketed around the loop.
///
///         The handler is the batch minter's OWNER as well as the batching
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
    IMintableERC20 public payToken;
    MockERC20 public bootToken;

    address public constant RECIPIENT = address(0xBEEF);

    uint256 public constant DISPATCHER_INDEX = 7;
    uint256 public constant START_PRICE = 1_000 ether;
    uint256 public constant GROWTH_BPS = 250;
    /// @dev Mirrors `BatchNFTMinterMultiToken.DUST_THRESHOLD` (internal there).
    uint256 public constant DUST_THRESHOLD = 1e6;

    /// @dev The payment token's transfer skim, in bps. `0` for a plain ERC20.
    uint256 public immutable feeBps;
    /// @dev `D`: what the minter pushes back per mint, mid-loop.
    uint256 public immutable donationPerMint;

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
    uint256 public qualifyingBatches;
    uint256 public nonQualifyingBatches;
    /// @dev Batches in which the payment token's fee actually bit, so a taxed
    ///      run cannot pass by never exercising the shortfall.
    uint256 public taxedBatches;
    /// @dev Batches in which the mint loop generated donate-forward `D`.
    uint256 public donatingBatches;

    constructor(address payToken_, uint256 feeBps_, uint256 donationPerMint_) {
        payToken = IMintableERC20(payToken_);
        feeBps = feeBps_;
        donationPerMint = donationPerMint_;

        bootToken = new MockERC20("BootToken", "BOOT");
        nft = new MockERC1155();
        minter = new MockITokenMinterV2();
        disp = new MockTokenDispatcherV2(address(bootToken));

        minter.setStakedToken(nft);
        minter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        minter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        minter.setDispatcher(DISPATCHER_INDEX, address(disp));

        if (donationPerMint_ != 0) {
            // Fund the minter generously; it donates to the batcher per mint.
            payToken.mint(address(minter), 1e30);
            minter.setPerMintDonation(address(payToken), donationPerMint_);
        }

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

    /// @dev What arrives when `amount` is transferred, after the token's skim.
    function _net(uint256 amount) internal view returns (uint256) {
        return amount - (amount * feeBps) / 10_000;
    }

    /// @dev The one call's context, carried in memory so `batchMintFuzzed`
    ///      stays inside the legacy code generator's stack limit.
    struct Ctx {
        uint256 count;
        uint256 nudge;
        uint256 pot;
        uint256 cost;
        uint256 paymentAmount;
        uint256 recipientBefore;
        uint256 selfBefore;
    }

    /// @notice The single fuzzed action: top the pot up by an arbitrary amount,
    ///         set an arbitrary `nudgeSize`, and batch an arbitrary `count`
    ///         against an arbitrary surplus (or shortfall).
    function batchMintFuzzed(uint256 countSeed, uint256 surplusSeed, uint256 nudgeSeed, uint256 potSeed) external {
        calls++;

        Ctx memory c;
        c.count = bound(countSeed, 1, 8);
        c.nudge = bound(nudgeSeed, 0, 10);
        // Deliberately allows a SHORTFALL as well as a surplus: `paymentAmount`
        // can land below the cumulative charge, which must revert rather than
        // draw on the pot.
        {
            uint256 quoteDelta = bound(surplusSeed, 0, 8_000 ether);
            uint256 potAdd = bound(potSeed, 0, 20_000 ether);
            batch.setNudgeSize(c.nudge);
            if (potAdd != 0) payToken.mint(address(batch), potAdd);

            c.pot = payToken.balanceOf(address(batch));
            c.cost = _cost(c.count);
            c.paymentAmount =
                surplusSeed % 4 == 0 ? (quoteDelta > c.cost ? 0 : c.cost - quoteDelta) : c.cost + quoteDelta;
        }

        payToken.mint(address(this), c.paymentAmount);
        payToken.approve(address(batch), c.paymentAmount);

        c.recipientBefore = payToken.balanceOf(RECIPIENT);
        c.selfBefore = payToken.balanceOf(address(this));

        uint256[] memory mins = new uint256[](1);

        try batch.batchMint(c.count, RECIPIENT, c.paymentAmount, mins) returns (uint256 totalPaid) {
            successes++;
            _recordSuccess(c, totalPaid);
        } catch {
            reverts++;
            // A rejected batch must be atomic: the pot is exactly where it was.
            if (payToken.balanceOf(address(batch)) != c.pot) potIntegrityHeld = false;
            if (payToken.balanceOf(RECIPIENT) != c.recipientBefore) potIntegrityHeld = false;
        }
    }

    function _recordSuccess(Ctx memory c, uint256 totalPaid) internal {
        uint256 refundReceived = payToken.balanceOf(address(this)) + c.paymentAmount - c.selfBefore;
        bool qualifies = c.nudge != 0 && c.count >= c.nudge;

        // What the contract was actually credited, and what it therefore owed
        // back. This mirrors step 5's `min(credited, paymentAmount)`; for
        // `feeBps == 0` it collapses to `paymentAmount`.
        uint256 budget = _net(c.paymentAmount);
        uint256 refundSent = budget - c.cost;
        if (refundSent / DUST_THRESHOLD == 0) refundSent = 0;

        // --- refund bound ---
        // Never more than the caller put in, and `totalPaid` agrees with what
        // left the contract (not with what the token delivered).
        if (refundReceived > c.paymentAmount) refundBoundHeld = false;
        if (totalPaid != c.paymentAmount - refundSent) refundBoundHeld = false;
        if (refundReceived != _net(refundSent)) refundBoundHeld = false;

        // --- pot integrity: all-or-nothing, never partial ---
        // The pot is asserted EXACTLY, from the outside: whatever the token and
        // the donations did, the contract must end holding the pot it started
        // with (non-qualifying) or none of it (qualifying), plus this batch's
        // own donations, which belong to the NEXT claimant, plus any
        // sub-threshold surplus that was left behind rather than refunded.
        uint256 expected = (qualifies ? 0 : c.pot) + _net(donationPerMint) * c.count + (budget - c.cost - refundSent);
        if (payToken.balanceOf(address(batch)) != expected) potIntegrityHeld = false;
        if (payToken.balanceOf(RECIPIENT) - c.recipientBefore != (qualifies ? _net(c.pot) : 0)) {
            potIntegrityHeld = false;
        }

        if (qualifies) {
            qualifyingBatches++;
        } else {
            nonQualifyingBatches++;
        }
        if (feeBps != 0 && c.paymentAmount != 0) taxedBatches++;
        if (donationPerMint != 0) donatingBatches++;
    }
}

/// @title `batchMint` budget invariants (plan §8.5 - §8.6)
///
/// Run-20 D-35 required these properties to be **established and tested**, not
/// shipped as an unvalidated patch. Story 029 makes them structural; this
/// harness pins them under fuzzed `count`, `paymentAmount`, `nudgeSize` and pot
/// size, in the configuration where the payment token and the reward token are
/// the same asset.
///
/// @dev Abstract so the same two invariants run over several payment-token
///      behaviours. A property that only holds for a well-behaved ERC20 is not
///      the structural property this story claims to have established.
abstract contract BudgetInvariantBase is StdInvariant, Test {
    BudgetInvariantHandler internal handler;

    function _install(BudgetInvariantHandler handler_) internal {
        handler = handler_;

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BudgetInvariantHandler.batchMintFuzzed.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev §8.5. `refund <= paymentAmount`, always. This is the property whose
    ///      violation was `ycn19h1`: a refund of `P + (A - C) + D` against a
    ///      `paymentAmount` of one wei. It now holds by construction, because
    ///      `budget` starts at no more than `paymentAmount` and only ever
    ///      decreases — and `totalPaid == paymentAmount - refund` is checked
    ///      alongside it, so the accounting cannot be satisfied by simply
    ///      refunding nothing.
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
    function afterInvariant() public view virtual {
        assertGt(handler.calls(), 0, "TRIPWIRE: the handler was never called");
        assertGt(handler.successes(), 0, "TRIPWIRE: no batch ever succeeded");
        assertGt(handler.qualifyingBatches(), 0, "TRIPWIRE: the qualifying payout branch was never exercised");
        assertGt(handler.nonQualifyingBatches(), 0, "TRIPWIRE: the non-qualifying branch was never exercised");
        assertGt(
            handler.reverts(), 0, "TRIPWIRE: an under-quoted batch never reverted, so the budget bound was never hit"
        );
    }
}

/// @notice Baseline: a well-behaved ERC20, with the mint loop generating
///         donate-forward `D` so the pot-integrity accounting has to separate
///         the caller's budget from money that arrives mid-loop.
contract BatchNFTMinterMultiTokenBudgetInvariantTest is BudgetInvariantBase {
    function setUp() public {
        MockERC20 token = new MockERC20("PayToken", "PAY");
        _install(new BudgetInvariantHandler(address(token), 0, 13 ether));
    }

    function afterInvariant() public view override {
        super.afterInvariant();
        assertGt(handler.donatingBatches(), 0, "TRIPWIRE: no batch generated donate-forward D");
    }
}

/// @notice The same two invariants over a payment token that skims 5% of every
///         transfer AND holds the pot.
///
/// @dev This is the configuration in which the pot-integrity claim was
///      previously false: `budget` was the quoted `paymentAmount`, so the refund
///      overdrew by the fee and took the difference out of `P`. It holds here
///      only because step 5 measures the credit. Deleting that measurement
///      turns this contract red while leaving the baseline above green — which
///      is the entire reason it exists as a separate run.
contract BatchNFTMinterMultiTokenTaxedBudgetInvariantTest is BudgetInvariantBase {
    function setUp() public {
        MockFeeOnTransferERC20 token = new MockFeeOnTransferERC20("Taxed", "TAX", 500);
        _install(new BudgetInvariantHandler(address(token), 500, 0));
    }

    function afterInvariant() public view override {
        super.afterInvariant();
        assertGt(handler.taxedBatches(), 0, "TRIPWIRE: the payment token's fee never actually bit");
    }
}
