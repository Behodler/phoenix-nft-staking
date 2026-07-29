// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NudgeStreamer, IMultiTokenNudgeWhitelist} from "../src/NudgeStreamer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNudgeDonor} from "./mocks/MockNudgeDonor.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockDonatingOnPullERC20} from "./mocks/MockDonatingOnPullERC20.sol";

/// @notice Minimal ERC20 with a configurable `decimals()`, used for the
///         USDC-like (6-dp) accrual test.
contract MockERC20Decimals is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock MultiToken batchMinter exposing only the whitelist membership
///         view the streamer's `registerStream` relies on. Doubles as a
///         concrete batchMinter address in `pullPendingStream` tests.
contract MockWhitelistBatchMinter is IMultiTokenNudgeWhitelist {
    mapping(address => bool) private _whitelisted;

    function setNudge(address token, bool allowed) external {
        _whitelisted[token] = allowed;
    }

    function isNudgeToken(address token) external view override returns (bool) {
        return _whitelisted[token];
    }

    /// @dev Lets the mock (acting as a batchMinter) flush its own stream.
    function pull(NudgeStreamer streamer, address token) external {
        streamer.pullPendingStream(token);
    }
}

/// @notice ERC20 whose `transfer` reenters `NudgeStreamer.pullPendingStream`
///         to prove the `nonReentrant` guard is wired.
contract MockReentrantStreamToken is ERC20 {
    NudgeStreamer public streamer;
    bool public armed;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(NudgeStreamer streamer_) external {
        streamer = streamer_;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            streamer.pullPendingStream(address(this));
        }
        return super.transfer(to, value);
    }
}

contract NudgeStreamerTest is Test {
    NudgeStreamer internal streamer;
    MockWhitelistBatchMinter internal batchMinter;
    MockERC20 internal token;
    MockNudgeDonor internal donor;

    address internal owner = makeAddr("streamerOwner");
    address internal notOwner = makeAddr("notOwner");

    uint256 internal constant DURATION = 1000;
    uint256 internal constant PRECISION = 1e18;

    event StreamRegistered(
        address indexed batchMinter, address indexed token, uint256 duration, uint256 rewardPerSecond
    );
    event Streamed(address indexed batchMinter, address indexed token, uint256 amount);
    event NudgeCollected(
        address indexed batchMinter, address indexed token, address indexed donor, uint256 amount, uint256 rewardPerSecond
    );

    function setUp() public {
        streamer = new NudgeStreamer(owner);
        batchMinter = new MockWhitelistBatchMinter();
        token = new MockERC20("Reward", "RWD");
        donor = new MockNudgeDonor();

        batchMinter.setNudge(address(token), true);
    }

    // ---- helpers ----

    function _register(uint256 duration) internal {
        vm.prank(owner);
        streamer.registerStream(address(batchMinter), address(token), duration);
    }

    /// @dev Fund `donor` and deposit `amount` into the (batchMinter, token) buffer.
    function _donate(uint256 amount) internal {
        token.mint(address(donor), amount);
        donor.donate(address(streamer), address(batchMinter), address(token), amount);
    }

    function _streamState(address bm, address tok)
        internal
        view
        returns (uint256 duration, uint256 buffer, uint256 rewardPerSecond, uint256 lastUpdate)
    {
        (duration, buffer, rewardPerSecond, lastUpdate) = streamer.streams(bm, tok);
    }

    // =====================================================================
    // registerStream
    // =====================================================================

    function test_registerStream_succeedsAndEmits() public {
        vm.expectEmit(true, true, false, true, address(streamer));
        emit StreamRegistered(address(batchMinter), address(token), DURATION, 0);

        _register(DURATION);

        (uint256 duration,, uint256 rate, uint256 lastUpdate) = _streamState(address(batchMinter), address(token));
        assertEq(duration, DURATION, "duration stored");
        assertEq(rate, 0, "rate zero with empty buffer");
        assertEq(lastUpdate, block.timestamp, "lastUpdate set to now");
    }

    function test_registerStream_revertsForNonWhitelistedToken() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                NudgeStreamer.NudgeStreamer__NotWhitelisted.selector, address(batchMinter), address(other)
            )
        );
        streamer.registerStream(address(batchMinter), address(other), DURATION);
    }

    function test_registerStream_revertsForNonMultiTokenTarget() public {
        // A plain ERC20 does not implement `isNudgeToken`; the staticcall reverts.
        MockERC20 notABatchMinter = new MockERC20("NotBM", "NBM");
        vm.prank(owner);
        vm.expectRevert();
        streamer.registerStream(address(notABatchMinter), address(token), DURATION);
    }

    function test_registerStream_revertsForZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(NudgeStreamer.NudgeStreamer__ZeroDuration.selector);
        streamer.registerStream(address(batchMinter), address(token), 0);
    }

    function test_registerStream_revertsForNonOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        streamer.registerStream(address(batchMinter), address(token), DURATION);
    }

    function test_registerStream_reRegisterSettlesOldAccrualFirst() public {
        _register(DURATION);
        _donate(1000);

        vm.warp(block.timestamp + DURATION / 2); // half accrued

        uint256 bmBefore = token.balanceOf(address(batchMinter));

        // Re-register with a new (shorter) window; the 500 accrued so far must
        // settle to the batchMinter at the OLD rate before the recompute.
        vm.prank(owner);
        streamer.registerStream(address(batchMinter), address(token), DURATION / 2);

        assertEq(token.balanceOf(address(batchMinter)) - bmBefore, 500, "old accrual settled on re-register");

        (uint256 duration, uint256 buffer, uint256 rate,) = _streamState(address(batchMinter), address(token));
        assertEq(duration, DURATION / 2, "new duration stored");
        assertEq(buffer, 500, "buffer is the un-streamed remainder");
        assertEq(rate, (500 * PRECISION) / (DURATION / 2), "rate recomputed over new window");
    }

    // =====================================================================
    // collectNudge
    // =====================================================================

    function test_collectNudge_depositRecomputesRate() public {
        _register(DURATION);

        uint256 amount = 1000;
        token.mint(address(donor), amount);

        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeCollected(address(batchMinter), address(token), address(donor), amount, (amount * PRECISION) / DURATION);

        donor.donate(address(streamer), address(batchMinter), address(token), amount);

        (, uint256 buffer, uint256 rate,) = _streamState(address(batchMinter), address(token));
        assertEq(buffer, amount, "buffer credited");
        assertEq(rate, (amount * PRECISION) / DURATION, "rate recomputed on deposit");
    }

    function test_collectNudge_settlesAccruedToRecipientBeforeDeposit() public {
        _register(DURATION);
        _donate(1000); // rate = 1000*1e18/1000 = 1e18 per sec

        vm.warp(block.timestamp + DURATION / 2); // 500 accrued

        uint256 bmBefore = token.balanceOf(address(batchMinter));

        _donate(1000); // second deposit settles the 500 first

        assertEq(token.balanceOf(address(batchMinter)) - bmBefore, 500, "accrued settled to recipient at old rate");

        (, uint256 buffer, uint256 rate,) = _streamState(address(batchMinter), address(token));
        assertEq(buffer, 1500, "buffer = remainder 500 + new 1000");
        assertEq(rate, (1500 * PRECISION) / DURATION, "rate recomputed against new buffer");
    }

    function test_collectNudge_revertsWhenUnregistered() public {
        token.mint(address(donor), 1000);
        vm.expectRevert(NudgeStreamer.NudgeStreamer__NotRegistered.selector);
        donor.donate(address(streamer), address(batchMinter), address(token), 1000);
    }

    function test_collectNudge_revertsForZeroAmount() public {
        _register(DURATION);
        vm.expectRevert(NudgeStreamer.NudgeStreamer__ZeroAmount.selector);
        donor.donate(address(streamer), address(batchMinter), address(token), 0);
    }

    // =====================================================================
    // Linear accrual + pendingStream
    // =====================================================================

    function test_linearAccrual_pendingMatchesElapsedFraction() public {
        _register(DURATION);
        _donate(1000);

        uint256 t0 = block.timestamp;

        vm.warp(t0 + 250);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 250, "25% elapsed");

        vm.warp(t0 + 500);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 500, "50% elapsed");

        vm.warp(t0 + 999);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 999, "99.9% elapsed");
    }

    function test_pendingStream_matchesSettledAmount() public {
        _register(DURATION);
        _donate(1000);

        vm.warp(block.timestamp + 300);

        uint256 pending = streamer.pendingStream(address(batchMinter), address(token));
        assertEq(pending, 300, "pending computed");

        uint256 bmBefore = token.balanceOf(address(batchMinter));
        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token));

        assertEq(token.balanceOf(address(batchMinter)) - bmBefore, pending, "settled equals prior pending");
    }

    function test_pendingStream_zeroForUnregistered() public view {
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 0, "unregistered -> 0");
    }

    // =====================================================================
    // min(..., buffer) cap
    // =====================================================================

    function test_settle_cappedByBufferAtFullDuration() public {
        _register(DURATION);
        _donate(1000);

        vm.warp(block.timestamp + DURATION); // exactly full window
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 1000, "full buffer at duration");
    }

    function test_settle_cappedByBufferBeyondDuration() public {
        _register(DURATION);
        _donate(1000);

        vm.warp(block.timestamp + DURATION * 10); // far past the window

        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 1000, "capped at buffer, no over-accrual");

        uint256 bmBefore = token.balanceOf(address(batchMinter));
        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token));

        assertEq(token.balanceOf(address(batchMinter)) - bmBefore, 1000, "transfers only what it holds");
        (, uint256 buffer,,) = _streamState(address(batchMinter), address(token));
        assertEq(buffer, 0, "buffer fully drained, not negative");
    }

    // =====================================================================
    // Dust rounds to protocol
    // =====================================================================

    function test_dust_roundsToProtocol() public {
        _register(DURATION);
        _donate(100); // rate = 100*1e18/1000 = 1e17 (0.1 unit/sec)

        uint256 t0 = block.timestamp;

        // Below 10 seconds the floored accrual is 0 — the sub-unit dust stays in
        // the buffer (protocol's favour), it is never rounded out to the recipient.
        vm.warp(t0 + 5);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 0, "0.5 unit floors to 0");

        uint256 bmBefore = token.balanceOf(address(batchMinter));
        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token));
        assertEq(token.balanceOf(address(batchMinter)), bmBefore, "no dust leaked to recipient");
        (, uint256 buffer,,) = _streamState(address(batchMinter), address(token));
        assertEq(buffer, 100, "dust retained in buffer");

        // Dust is not lost: the earlier zero-settle pull advanced `lastUpdate`
        // (extending the tail slightly), but the full buffer still streams out
        // — it is retained, never forfeited. Warp past the window; the buffer
        // cap confirms the entire 100 is claimable.
        vm.warp(t0 + DURATION * 2);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 100, "all dust eventually streams");
    }

    // =====================================================================
    // pullPendingStream
    // =====================================================================

    function test_pullPendingStream_noopWhenUnregistered() public {
        // msg.sender = an unregistered batchMinter; must not revert, must move nothing.
        uint256 balBefore = token.balanceOf(address(batchMinter));
        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token)); // duration == 0 -> early return
        assertEq(token.balanceOf(address(batchMinter)), balBefore, "no-op, no transfer");
    }

    function test_pullPendingStream_transfersToCallingBatchMinter() public {
        _register(DURATION);
        _donate(1000);

        vm.warp(block.timestamp + 400);

        // The recipient is the CALLER (msg.sender), not an argument.
        uint256 bmBefore = token.balanceOf(address(batchMinter));

        vm.expectEmit(true, true, false, true, address(streamer));
        emit Streamed(address(batchMinter), address(token), 400);

        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token));

        assertEq(token.balanceOf(address(batchMinter)) - bmBefore, 400, "streamed to msg.sender");

        (, uint256 buffer,, uint256 lastUpdate) = _streamState(address(batchMinter), address(token));
        assertEq(buffer, 600, "buffer reduced by settled");
        assertEq(lastUpdate, block.timestamp, "lastUpdate advanced");
    }

    function test_pullPendingStream_doesNotRecomputeRate() public {
        _register(DURATION);
        _donate(1000);
        (,, uint256 rateBefore,) = _streamState(address(batchMinter), address(token));

        vm.warp(block.timestamp + 500);
        vm.prank(address(batchMinter));
        streamer.pullPendingStream(address(token));

        (,, uint256 rateAfter,) = _streamState(address(batchMinter), address(token));
        assertEq(rateAfter, rateBefore, "flush must NOT reset the streaming window");

        // Because the window was not reset, the remaining 500 drains over the
        // remaining 500 seconds — i.e. depletion completes at the original t0+DURATION.
        vm.warp(block.timestamp + 500);
        assertEq(streamer.pendingStream(address(batchMinter), address(token)), 500, "remainder drains on original schedule");
    }

    // =====================================================================
    // Reentrancy guard
    // =====================================================================

    function test_pullPendingStream_reentrancyGuarded() public {
        MockReentrantStreamToken evil = new MockReentrantStreamToken();
        MockWhitelistBatchMinter bm = new MockWhitelistBatchMinter();
        bm.setNudge(address(evil), true);

        vm.prank(owner);
        streamer.registerStream(address(bm), address(evil), DURATION);

        // Seed the buffer directly (donor path), then arm the reentry.
        evil.mint(address(this), 1000);
        evil.approve(address(streamer), 1000);
        // Deposit via collectNudge as this contract (a "donor").
        streamer.collectNudge(address(bm), address(evil), 1000);

        vm.warp(block.timestamp + 500); // 500 accrued -> settle will transfer
        evil.arm(streamer);

        // bm flushes; the settle transfer reenters pullPendingStream and trips the guard.
        vm.prank(address(bm));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        streamer.pullPendingStream(address(evil));
    }

    // =====================================================================
    // 6-decimal (USDC-like) scaling — native units, no decimal normalization
    // =====================================================================

    function test_sixDecimalToken_subUnitPerSecondRatePreserved() public {
        MockERC20Decimals usdc = new MockERC20Decimals("USD Coin", "USDC", 6);
        MockWhitelistBatchMinter bm = new MockWhitelistBatchMinter();
        bm.setNudge(address(usdc), true);

        assertEq(usdc.decimals(), 6, "6-dp token");

        // 100 USDC = 100e6 native units, streamed over 2e8 seconds.
        // rate = 1e8 * 1e18 / 2e8 = 5e17 scaled = 0.5 native-unit/sec (SUB-UNIT).
        // Without the 1e18 scaling, buffer/duration = 1e8/2e8 = 0 and NOTHING
        // would ever accrue.
        uint256 amount = 100e6;
        uint256 duration = 2e8;

        vm.prank(owner);
        streamer.registerStream(address(bm), address(usdc), duration);

        usdc.mint(address(this), amount);
        usdc.approve(address(streamer), amount);
        streamer.collectNudge(address(bm), address(usdc), amount);

        (,, uint256 rate,) = _streamState(address(bm), address(usdc));
        assertEq(rate, 5e17, "sub-unit-per-second rate retained via 1e18 scaling");

        uint256 t0 = block.timestamp;

        // 1 second -> 0.5 unit -> floors to 0 (dust withheld).
        vm.warp(t0 + 1);
        assertEq(streamer.pendingStream(address(bm), address(usdc)), 0, "0.5 native unit floors to 0");

        // 2 seconds -> exactly 1 native unit (no decimal normalization).
        vm.warp(t0 + 2);
        assertEq(streamer.pendingStream(address(bm), address(usdc)), 1, "exactly 1 native unit after 2s");

        // Full window -> entire 100 USDC in native units, capped by buffer.
        vm.warp(t0 + duration);
        assertEq(streamer.pendingStream(address(bm), address(usdc)), amount, "full 100e6 native units");

        // And it actually transfers 100e6 native units to the batchMinter.
        uint256 bmBefore = usdc.balanceOf(address(bm));
        vm.prank(address(bm));
        streamer.pullPendingStream(address(usdc));
        assertEq(usdc.balanceOf(address(bm)) - bmBefore, amount, "streamed native units, no normalization");
    }

    // =====================================================================
    // M-01 — the buffer is credited with what was RECEIVED, not what was sent
    //
    // NOTE ON `MockFeeOnTransferERC20` REUSE. That mock was introduced as the
    // `docs/multi-token-nudge.md` §4.4 witness for a DIFFERENT contract and a
    // DIFFERENT property: reward DELIVERY out of `BatchNFTMinter*`, where
    // `minRewards[i]` is a floor on the pre-transfer balance and under-delivery
    // to `recipient` is documented-not-defended. The tests below are about
    // custody CREDIT into `NudgeStreamer`, which IS defended. The streamer
    // holds a single pooled balance per token across every
    // `(batchMinter, token)` pair while `_accrued`'s cap is per stream, so an
    // over-credit on one pair silently consumes a sibling pair's backing. The
    // measurement mirrors the house pattern at
    // `BatchNFTMinterMultiToken.sol:584-611`. Reusing the same adversary at a
    // second site is not a contradiction of §4.4.
    // =====================================================================

    uint256 internal constant TAXED_BPS = 500; // 5%
    uint256 internal constant BIG_DONATION = 100_000e18;

    /// @dev Deploy a taxed token, whitelist it on a fresh batchMinter, and
    ///      register a `DURATION` stream for the pair.
    function _registerTaxed(uint256 feeBps)
        internal
        returns (MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm)
    {
        taxed = new MockFeeOnTransferERC20("Taxed", "TAX", feeBps);
        bm = new MockWhitelistBatchMinter();
        bm.setNudge(address(taxed), true);
        vm.prank(owner);
        streamer.registerStream(address(bm), address(taxed), DURATION);
    }

    /// @dev Fund the donor (mint is untaxed) and donate through `collectNudge`.
    function _donateTaxed(MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm, uint256 amount) internal {
        taxed.mint(address(donor), amount);
        donor.donate(address(streamer), address(bm), address(taxed), amount);
    }

    /// @notice M-01, case A. A 5%-taxed donation of 100_000e18 delivers only
    ///         95_000e18 into custody. The buffer must credit the receipt, not
    ///         the request: against the pre-fix code this asserted
    ///         `buffer == 100_000e18` while custody was 95_000e18, which is the
    ///         over-credit the finding names.
    function test_collectNudge_taxedTokenCreditsMeasuredReceipt() public {
        (MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm) = _registerTaxed(TAXED_BPS);
        _donateTaxed(taxed, bm, BIG_DONATION);

        uint256 expectedCustody = BIG_DONATION - (BIG_DONATION * TAXED_BPS) / 10_000;

        (, uint256 buffer, uint256 rate,) = _streamState(address(bm), address(taxed));
        assertEq(taxed.balanceOf(address(streamer)), expectedCustody, "custody is the post-tax receipt");
        assertEq(buffer, expectedCustody, "buffer credits the amount RECEIVED, not the amount sent");
        assertEq(rate, (expectedCustody * PRECISION) / DURATION, "rate follows the corrected credit");
    }

    /// @notice The snapshot must be taken AFTER `_settle`, not at function
    ///         entry. `_settle`'s outbound transfer moves the streamer's
    ///         balance mid-call, so an entry snapshot measures the settle and
    ///         the pull together and mis-credits the buffer.
    function test_collectNudge_snapshotIsTakenAfterSettleNotAtEntry() public {
        (MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm) = _registerTaxed(TAXED_BPS);
        _donateTaxed(taxed, bm, BIG_DONATION);

        uint256 firstReceipt = BIG_DONATION - (BIG_DONATION * TAXED_BPS) / 10_000; // 95_000e18

        // Half the window elapses, so the second donation settles half the
        // first receipt outbound before it pulls anything in.
        vm.warp(block.timestamp + DURATION / 2);
        uint256 settled = firstReceipt / 2;
        assertEq(streamer.pendingStream(address(bm), address(taxed)), settled, "half the first receipt accrued");

        _donateTaxed(taxed, bm, BIG_DONATION);

        // Correct: remainder + the second receipt, measured across the pull only.
        // A function-entry snapshot would instead net the outbound settle
        // against the inbound pull and credit `firstReceipt - settled` here.
        (, uint256 buffer,,) = _streamState(address(bm), address(taxed));
        assertEq(buffer, (firstReceipt - settled) + firstReceipt, "credit measures the pull, not the settle");
        assertEq(taxed.balanceOf(address(streamer)), buffer, "buffer still exactly backed by custody");
    }

    /// @notice A fee-free token is credited byte-identically to the pre-fix
    ///         behaviour: measuring must not regress honest tokens.
    function test_collectNudge_feeFreeTokenCreditUnchanged() public {
        (MockFeeOnTransferERC20 clean, MockWhitelistBatchMinter bm) = _registerTaxed(0);
        _donateTaxed(clean, bm, BIG_DONATION);

        (, uint256 buffer, uint256 rate,) = _streamState(address(bm), address(clean));
        assertEq(buffer, BIG_DONATION, "no fee -> credit is the full amount");
        assertEq(rate, (BIG_DONATION * PRECISION) / DURATION, "rate identical to the pre-fix derivation");
        assertEq(clean.balanceOf(address(streamer)), BIG_DONATION, "custody matches the buffer exactly");
    }

    /// @notice A token that pushes a third party's balance INTO the streamer
    ///         during the pull must not inflate the credit. The credit is
    ///         `min(received, amount)`; the surplus stays uncredited idle
    ///         balance, which is protocol-favourable.
    function test_collectNudge_donationDuringPullCannotInflateCredit() public {
        MockDonatingOnPullERC20 pushy = new MockDonatingOnPullERC20("Pushy", "PSH");
        MockWhitelistBatchMinter bm = new MockWhitelistBatchMinter();
        bm.setNudge(address(pushy), true);
        vm.prank(owner);
        streamer.registerStream(address(bm), address(pushy), DURATION);

        address thirdParty = makeAddr("thirdParty");
        uint256 surplus = 7_000e18;
        pushy.mint(thirdParty, surplus);
        pushy.setDonation(thirdParty, surplus);

        pushy.mint(address(donor), BIG_DONATION);
        donor.donate(address(streamer), address(bm), address(pushy), BIG_DONATION);

        (, uint256 buffer, uint256 rate,) = _streamState(address(bm), address(pushy));
        assertEq(buffer, BIG_DONATION, "credit capped at the amount sent");
        assertEq(rate, (BIG_DONATION * PRECISION) / DURATION, "rate derived from the capped credit");
        assertEq(
            pushy.balanceOf(address(streamer)), BIG_DONATION + surplus, "surplus is held but deliberately uncredited"
        );
    }

    /// @notice A 100%-fee token delivers nothing from a non-zero `amount`.
    ///         That is a distinct operator mistake from passing `amount == 0`,
    ///         so it gets its own error.
    function test_collectNudge_revertsWhenNothingIsReceived() public {
        (MockFeeOnTransferERC20 confiscatory, MockWhitelistBatchMinter bm) = _registerTaxed(10_000);
        confiscatory.mint(address(donor), BIG_DONATION);

        vm.expectRevert(NudgeStreamer.NudgeStreamer__ZeroReceived.selector);
        donor.donate(address(streamer), address(bm), address(confiscatory), BIG_DONATION);
    }

    /// @notice `NudgeCollected.amount` carries the CREDITED receipt, which is
    ///         the value `rewardPerSecond` is derived from. No fifth field is
    ///         added — that would be an event-ABI break for downstream indexers.
    function test_collectNudge_emitsReceivedAmountAndConsistentRate() public {
        (MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm) = _registerTaxed(TAXED_BPS);
        taxed.mint(address(donor), BIG_DONATION);

        uint256 received = BIG_DONATION - (BIG_DONATION * TAXED_BPS) / 10_000;

        vm.expectEmit(true, true, true, true, address(streamer));
        emit NudgeCollected(address(bm), address(taxed), address(donor), received, (received * PRECISION) / DURATION);

        donor.donate(address(streamer), address(bm), address(taxed), BIG_DONATION);

        (,, uint256 rate,) = _streamState(address(bm), address(taxed));
        assertEq(rate, (received * PRECISION) / DURATION, "emitted rate matches stored rate");
    }

    /// @notice Across N donations of a taxed token the buffer tracks pooled
    ///         custody rather than drifting further above it with each top-up.
    function test_collectNudge_taxedMultiDonationBufferTracksCustody() public {
        (MockFeeOnTransferERC20 taxed, MockWhitelistBatchMinter bm) = _registerTaxed(TAXED_BPS);

        for (uint256 i = 0; i < 4; i++) {
            _donateTaxed(taxed, bm, BIG_DONATION);
            (, uint256 buffer,,) = _streamState(address(bm), address(taxed));
            assertEq(buffer, taxed.balanceOf(address(streamer)), "buffer never exceeds pooled custody");
        }
    }
}
