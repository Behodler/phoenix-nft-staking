// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
// PoC — yield-claim-nft submission `ycn19h1` (CONDITIONAL High), ported upstream
//
// Source: `reports/yield-claim-nft-19/pocs/run19-Tier3Nudge.t.sol`,
//         `Run19_T1_PaymentTokenCollision` + its `Run19Base` fixture.
//
// The audit-side original wires the REAL `NFTMinterV2`, `NudgeRatchet`,
// `Uniboost` and `GatherV2`. Those live in the `yield-claim-nft` sibling, which
// this repo consumes as INTERFACES ONLY (`lib/mutable/`), so the port swaps them
// for this repo's `MockITokenMinterV2` / `MockTokenDispatcherV2` doubles while
// keeping the REAL `NudgeStreamer` (which lives here) and the REAL
// `BatchNFTMinterMultiToken` under test. The donor leg is the real
// `collectNudge` path via `MockNudgeDonor`, exactly as `NudgeRatchet.dispatch`
// drives it in production.
//
// ANTI-VACUITY POLICY (carried over from the audit harness): the pot is seeded
// through the real streamer, and every test asserts a non-zero precondition
// (`TRIPWIRE:`) BEFORE asserting the property, so a harness that silently stops
// moving value fails loudly rather than passing vacuously.
//
// PoC CONVENTION: **PASS = defect reproduced.** These tests are written against
// the FIXED contract, so they must flip red -> green when the budget-tracking
// change lands. Before the change `test_PaymentTokenAsNudge_*` fail because a
// `count = 1` batch paying ONE WEI walks off with 190 USDC of a 200 USDC pot;
// after it, the same call reverts `BatchMint__PaymentBudgetExhausted(0, 10e6, 1)`
// and the pot is untouched.
// =============================================================================

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {NudgeStreamer} from "../src/NudgeStreamer.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNudgeDonor} from "./mocks/MockNudgeDonor.sol";

/// @dev 6-dp USDC stand-in, so the ported figures stay in the audit's units
///      (200 USDC pot, 10 USDC per mint). The audit original carried an
///      optional blacklist for its T2 arm; T1 does not use it, so it is
///      omitted here.
contract MockUSDC6 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title `ycn19h1` — payment-token/nudge-token collision
///
/// One owner transaction (`setDispatcherIndex` -> a USDC-prime dispatcher)
/// turns an already-whitelisted nudge token into the DERIVED payment token.
/// Under the pre-change contract the whole nudge pot then leaves through the
/// step-10 balance sweep to any unprivileged `count = 1` caller, bypassing the
/// `nudgeSize` gate entirely: the mint itself is funded out of the pot, because
/// step 6 granted the minter `type(uint256).max` over the contract's whole
/// balance.
contract PoC_PaymentTokenCollisionTest is Test {
    NudgeStreamer internal streamer;
    BatchNFTMinterMultiToken internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockERC1155 internal nft;
    MockNudgeDonor internal donor;

    /// @dev The USDC-prime dispatcher (stands in for `NudgeRatchet`).
    MockTokenDispatcherV2 internal ratchet;
    /// @dev The PAY-prime dispatcher (stands in for `GatherV2`) — the "safe"
    ///      pinned index the batch minter is configured against.
    MockTokenDispatcherV2 internal payDispatcher;

    MockUSDC6 internal usdc;
    MockERC20 internal payToken;

    address internal owner = makeAddr("batchOwner");
    address internal attacker = makeAddr("attacker");
    address internal nftRecipient = address(0xFACE);

    uint256 internal constant RATCHET_INDEX = 1; // USDC-prime
    uint256 internal constant PAY_INDEX = 7; // PAY-prime (the pinned index)
    uint256 internal constant RATCHET_PRICE = 10e6; // 10 USDC per mint
    uint256 internal constant MINT_PRICE = 1e18; // PAY per mint
    uint256 internal constant NUDGE_SIZE = 5;
    uint256 internal constant STREAM_DURATION = 1000;

    /// @dev 20 honest mints at 10 USDC == the audit's 200 USDC pot.
    uint256 internal constant HONEST_MINTS = 20;

    function setUp() public {
        usdc = new MockUSDC6();
        payToken = new MockERC20("Pay", "PAY");
        nft = new MockERC1155();
        donor = new MockNudgeDonor();

        nftMinter = new MockITokenMinterV2();
        nftMinter.setStakedToken(nft);

        ratchet = new MockTokenDispatcherV2(address(usdc));
        payDispatcher = new MockTokenDispatcherV2(address(payToken));

        // index 1 — USDC-prime, flat price (growth 0, as in the audit fixture)
        nftMinter.setConfig(RATCHET_INDEX, RATCHET_PRICE, 0);
        nftMinter.setPrimeToken(RATCHET_INDEX, address(usdc));
        nftMinter.setDispatcher(RATCHET_INDEX, address(ratchet));

        // index 7 — PAY-prime, the pinned "safe" index
        nftMinter.setConfig(PAY_INDEX, MINT_PRICE, 0);
        nftMinter.setPrimeToken(PAY_INDEX, address(payToken));
        nftMinter.setDispatcher(PAY_INDEX, address(payDispatcher));

        batch = new BatchNFTMinterMultiToken(owner);
        streamer = new NudgeStreamer(owner);

        vm.startPrank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        batch.setDispatcherIndex(PAY_INDEX);
        batch.setNudgeSize(NUDGE_SIZE);
        // Admissible at write time: the derived payment token is PAY, not USDC.
        batch.setNudgeTokenWhitelist(address(usdc), true);
        batch.setNudgeStreamer(address(streamer));
        streamer.registerStream(address(batch), address(usdc), STREAM_DURATION);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- //
    // helpers
    // ---------------------------------------------------------------- //

    function _mins(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    /// @dev One honest user mint on the USDC-prime index, plus the donation leg
    ///      that mint triggers in production: `NudgeRatchet.dispatch` forwards
    ///      the mint's USDC into the streamer via `collectNudge`. The mock
    ///      minter has no dispatcher routing, so the two legs are driven
    ///      explicitly — the real `NudgeStreamer` still does the buffering.
    function _mintThroughRatchet(address user) internal {
        usdc.mint(user, RATCHET_PRICE);
        vm.startPrank(user);
        usdc.approve(address(nftMinter), RATCHET_PRICE);
        nftMinter.mint(RATCHET_INDEX, user);
        vm.stopPrank();

        usdc.mint(address(donor), RATCHET_PRICE);
        donor.donate(address(streamer), address(batch), address(usdc), RATCHET_PRICE);
    }

    /// @dev Seed the pot the way production does: real mints, real donor path,
    ///      real streamer, then let the window elapse so it is claimable.
    ///      Returns the batch-minter's USDC balance after the flush.
    function _accumulatePot() internal returns (uint256) {
        for (uint256 i; i < HONEST_MINTS; ++i) {
            _mintThroughRatchet(address(uint160(0xA000 + i)));
        }
        (, uint256 buffer,,) = streamer.streams(address(batch), address(usdc));
        assertEq(buffer, HONEST_MINTS * RATCHET_PRICE, "TRIPWIRE: donors really funded the stream");
        assertEq(
            nft.balanceOf(address(uint160(0xA000)), RATCHET_INDEX), 1, "TRIPWIRE: the honest mints really happened"
        );

        vm.warp(block.timestamp + STREAM_DURATION);
        assertEq(
            streamer.pendingStream(address(batch), address(usdc)),
            HONEST_MINTS * RATCHET_PRICE,
            "TRIPWIRE: whole donation is claimable"
        );

        // Flush it onto the batch-minter (any batchMint would do this at step 3.5).
        vm.prank(address(batch));
        streamer.pullPendingStream(address(usdc));
        uint256 pot = usdc.balanceOf(address(batch));
        assertEq(pot, HONEST_MINTS * RATCHET_PRICE, "TRIPWIRE: pot really landed on the batch-minter");
        return pot;
    }

    /// @dev The single owner transaction that creates the collision, plus the
    ///      precondition proof that it really did.
    function _repointAtUsdcPrimeDispatcher() internal {
        vm.prank(owner);
        batch.setDispatcherIndex(RATCHET_INDEX);

        (address disp,,,) = nftMinter.configs(RATCHET_INDEX);
        assertEq(disp, address(ratchet), "index 1 is the USDC-prime dispatcher");
        assertEq(ratchet.primeToken(), address(usdc), "TRIPWIRE: derived payment token is now USDC");
        assertTrue(batch.isNudgeToken(address(usdc)), "USDC is still whitelisted as a nudge token");
    }

    /// @dev Run the `count = 1`, ONE WEI attack and report how much USDC the
    ///      caller extracted, net of what they supplied.
    ///
    ///      Deliberately a LOW-LEVEL call rather than `vm.expectRevert`, so this
    ///      helper measures the same thing whether the contract lets the sweep
    ///      through (pre-change: 190 USDC leaves) or rejects the batch
    ///      (post-change: revert, nothing moves). That is what lets one test
    ///      body serve as both the red reproduction and the green regression.
    function _extractedByCount1Attack() internal returns (uint256 extracted, bool succeeded) {
        usdc.mint(attacker, 1);
        uint256 attackerBefore = usdc.balanceOf(attacker);

        vm.startPrank(attacker);
        usdc.approve(address(batch), 1);
        (succeeded,) = address(batch)
            .call(abi.encodeWithSelector(batch.batchMint.selector, uint256(1), attacker, uint256(1), _mins(0)));
        vm.stopPrank();

        uint256 after_ = usdc.balanceOf(attacker);
        extracted = after_ > attackerBefore ? after_ - attackerBefore : 0;
    }

    // ================================================================ //
    // CONTROL — green before AND after the change
    // ================================================================ //

    /// @dev Before the repoint, USDC is a genuine nudge token: a `count = 1`
    ///      batch does not qualify, pays nothing out and sweeps nothing,
    ///      because the payment token is PAY and the USDC pot is untouched.
    function test_control_beforeRepoint_count1_capturesNothing() public {
        uint256 pot = _accumulatePot();
        assertGt(pot, 0, "TRIPWIRE: pot must be non-empty before the control run");

        payToken.mint(attacker, MINT_PRICE);
        vm.startPrank(attacker);
        payToken.approve(address(batch), MINT_PRICE);
        batch.batchMint(1, attacker, MINT_PRICE, _mins(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(attacker), 0, "control: no USDC leaks to a count=1 batcher");
        assertGe(usdc.balanceOf(address(batch)), pot, "control: pot stays in the batch minter");
        assertEq(nft.balanceOf(attacker, PAY_INDEX), 1, "control: the honest PAY-funded mint still happens");
    }

    // ================================================================ //
    // THE PoC — red before the change, green after
    // ================================================================ //

    /// @dev `ycn19h1`. The pot must not be extractable by a NON-QUALIFYING
    ///      batch, whatever the dispatcher is repointed at.
    ///
    ///      PRE-CHANGE (red): the sweep hands over `pot - RATCHET_PRICE`
    ///      = 190 USDC for a 1 wei payment, and the failure message prints the
    ///      extracted amount.
    ///      POST-CHANGE (green): the batch reverts because the caller's budget
    ///      (1 wei) cannot cover the next mint's price, so nothing moves.
    function test_PaymentTokenAsNudge_nonQualifyingBatchTakesNothing() public {
        uint256 pot = _accumulatePot();
        _repointAtUsdcPrimeDispatcher();

        uint256 potAtAttack = usdc.balanceOf(address(batch));
        assertGt(potAtAttack, RATCHET_PRICE, "TRIPWIRE: pot must exceed one mint's cost");
        assertEq(potAtAttack, pot, "TRIPWIRE: repoint moved no value on its own");
        assertLt(1, batch.nudgeSize(), "TRIPWIRE: count=1 is genuinely below the nudge gate");

        (uint256 extracted, bool succeeded) = _extractedByCount1Attack();

        emit log_named_uint("pot at attack (USDC 6dp)", potAtAttack);
        emit log_named_uint("extracted by count=1, 1-wei caller", extracted);

        assertEq(
            extracted,
            0,
            "ycn19h1: a NON-QUALIFYING batch extracted pot-sized value; the refund must derive from the caller's tracked budget, never from balanceOf"
        );
        assertEq(usdc.balanceOf(address(batch)), potAtAttack, "pot must be untouched by a non-qualifying batch");
        assertFalse(succeeded, "an under-funded batch must revert loudly, not draw on the pot");
        assertEq(nft.balanceOf(attacker, RATCHET_INDEX), 0, "no NFT may be minted out of the pot");
    }

    /// @dev The precise post-change failure mode the plan specifies: the
    ///      allowance is capped at the EXACT next mint price and cannot be
    ///      topped up out of the pot, so the 1-wei call is rejected at mint
    ///      index 0 naming the price and the remaining budget.
    ///
    ///      Uses `abi.encodeWithSignature` rather than the typed selector so
    ///      this file compiles — and therefore genuinely runs — against the
    ///      PRE-change contract too. A PoC that merely stops compiling is
    ///      inconclusive bit-rot, not a fix.
    function test_PaymentTokenAsNudge_underFundedBatchRevertsWithBudgetExhausted() public {
        _accumulatePot();
        _repointAtUsdcPrimeDispatcher();

        usdc.mint(attacker, 1);
        vm.startPrank(attacker);
        usdc.approve(address(batch), 1);
        vm.expectRevert(
            abi.encodeWithSignature("BatchMint__PaymentBudgetExhausted(uint256,uint256,uint256)", 0, RATCHET_PRICE, 1)
        );
        batch.batchMint(1, attacker, 1, _mins(0));
        vm.stopPrank();
    }

    /// @dev The `nudgeSize` gate must actually bind. `count(1) < nudgeSize(5)`,
    ///      so `qualifies` is false and `_payRewards` pays nothing — and after
    ///      the change no other path lets the funds out either.
    function test_PaymentTokenAsNudge_nudgeSizeGateIsNotBypassable() public {
        _accumulatePot();
        _repointAtUsdcPrimeDispatcher();
        assertEq(batch.nudgeSize(), NUDGE_SIZE, "gate is configured");

        uint256 potBefore = usdc.balanceOf(address(batch));
        (uint256 extracted,) = _extractedByCount1Attack();

        assertEq(extracted, 0, "the nudgeSize gate must not be bypassable via the refund path");
        assertEq(usdc.balanceOf(address(batch)), potBefore, "pot intact");
        assertEq(nft.balanceOf(nftRecipient, RATCHET_INDEX), 0, "no nudge payout path ran");
    }

    /// @dev It must not be repeatable across refills either. The audit original
    ///      asserted the second sweep captured the refill; here the pot must
    ///      survive both attempts and the refill on top.
    function test_PaymentTokenAsNudge_potSurvivesRepeatedAttemptsAcrossRefills() public {
        _accumulatePot();
        _repointAtUsdcPrimeDispatcher();

        (uint256 firstTake,) = _extractedByCount1Attack();
        assertEq(firstTake, 0, "first attempt captured nothing");
        uint256 potAfterFirst = usdc.balanceOf(address(batch));

        // Honest users keep minting; donations keep flowing into the same stream.
        for (uint256 i; i < 10; ++i) {
            _mintThroughRatchet(address(uint160(0xB000 + i)));
        }
        vm.warp(block.timestamp + STREAM_DURATION);

        uint256 refilled = streamer.pendingStream(address(batch), address(usdc));
        assertEq(refilled, 10 * RATCHET_PRICE, "TRIPWIRE: pot must have refilled");

        (uint256 secondTake,) = _extractedByCount1Attack();
        assertEq(secondTake, 0, "second attempt captured nothing either");

        // The refill is flushed into the pot by the attempted batch's step 3.5
        // and stays there for a genuinely qualifying claimant.
        assertEq(usdc.balanceOf(address(batch)), potAfterFirst, "flushless revert leaves the pot exactly as it was");
        assertEq(
            streamer.pendingStream(address(batch), address(usdc)), refilled, "refill still buffered for a real claim"
        );
    }

    /// @dev The other half of the property: a GENUINELY qualifying batch, which
    ///      pays for `nudgeSize` real mints out of its own budget, is still paid
    ///      the pot. The collision must be made SAFE, not merely blocked — if
    ///      this test fails the fix has bricked the feature instead of fixing it.
    function test_PaymentTokenAsNudge_qualifyingBatchStillEarnsThePot() public {
        uint256 pot = _accumulatePot();
        _repointAtUsdcPrimeDispatcher();

        uint256 cost = NUDGE_SIZE * RATCHET_PRICE; // growth is 0 on this index
        usdc.mint(attacker, cost);
        vm.startPrank(attacker);
        usdc.approve(address(batch), cost);
        batch.batchMint(NUDGE_SIZE, nftRecipient, cost, _mins(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(nftRecipient), pot, "a qualifying batcher is paid the whole pot as a nudge");
        assertEq(usdc.balanceOf(attacker), 0, "the caller's budget was fully consumed by the real mints");
        assertEq(nft.balanceOf(nftRecipient, RATCHET_INDEX), NUDGE_SIZE, "nudgeSize real mints were paid for");
    }
}
