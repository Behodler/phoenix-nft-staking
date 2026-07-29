// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockNonDecrementingAllowanceERC20} from "./mocks/MockNonDecrementingAllowanceERC20.sol";
import {MockDonatingOnPullERC20} from "./mocks/MockDonatingOnPullERC20.sol";
import {MockAllowanceRecordingMinterV2} from "./mocks/MockAllowanceRecordingMinterV2.sol";

/// @dev The `mint(address,uint256)` faculty every mock ERC20 in this repo
///      exposes, so the isolated-stack helpers can be written once and driven
///      with a well-behaved, a non-decrementing-allowance, or a fee-on-transfer
///      token interchangeably.
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title BatchNFTMinterMultiToken — budget-tracked refund (story 029)
///
/// The payment token IS a whitelisted nudge token in this fixture. That
/// construct used to be forbidden at admin time and silently skipped at
/// runtime; story 029 deleted the runtime skip and made the construct
/// **safe by construction**, and story 032 deleted the admin-time rejection
/// that had been left standing as defence in depth. Safety comes from the
/// refund deriving from a locally-tracked `budget` — provably the
/// caller's money and nothing else — rather than from
/// `paymentToken.balanceOf(address(this))`, which conflates three unrelated
/// pools:
///
///   `P` — the standing nudge pot         (belongs to the next qualifying batch)
///   `A - C` — unspent caller budget      (belongs to `msg.sender`)
///   `D` — this batch's own donations     (belongs to the NEXT claimant, §4.2)
///
/// The suite pins the three properties that follow:
///   - **Solvency** — the refund needs `A - C`, the balance holds
///     `P + A - C + D >= A - C`.
///   - **Pot integrity** — `refund <= budget <= A`, for any `count`, any
///     `nudgeSize`, any dispatcher index.
///   - **Token-behaviour independence** — every `forceApprove` is an ABSOLUTE
///     target, so correctness does not depend on whether the token decrements
///     allowance on `transferFrom`.
///
/// Closes yield-claim-nft submission `ycn19h1`; the reproduction itself lives in
/// `test/PoC_PaymentTokenCollision.t.sol`.
contract BatchNFTMinterMultiTokenBudgetTest is Test {
    BatchNFTMinterMultiToken internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;

    /// @dev BOTH the derived payment token AND whitelist slot 0.
    MockERC20 internal payToken;
    /// @dev A plain, non-colliding nudge token in whitelist slot 1, so every
    ///      assertion about the colliding entry has a control beside it.
    MockERC20 internal rewardB;
    /// @dev Holds the dispatcher's prime slot only while `payToken` is being
    ///      whitelisted, so this suite reaches the collision by REPOINTING: the
    ///      owner moves the dispatcher's prime token afterwards, out from under
    ///      an existing whitelist entry.
    ///
    ///      This decoy originally existed because `setNudgeTokenWhitelist`
    ///      refused the CURRENT payment token outright. Since story-032 it does
    ///      not, and whitelisting `payToken` directly would work — so the decoy
    ///      is now ONE of two ways in, not the only one. It is kept
    ///      deliberately: repointing remains a genuine production route to the
    ///      collision (the owner can change the derived payment token under any
    ///      existing entry at any time), and this suite plus
    ///      `PoC_PaymentTokenCollision.t.sol` are the only coverage of it. The
    ///      direct-whitelist route is covered in
    ///      `BatchNFTMinterMultiTokenNudge.t.sol` and
    ///      `BatchNFTMinterMultiTokenNudgeCore.t.sol`.
    MockERC20 internal bootToken;

    address internal owner = makeAddr("batchOwner");
    address internal caller = address(0xCAFE);
    address internal recipient = address(0xBEEF);

    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250; // 2.5% per mint
    uint256 internal constant NUDGE_SIZE = 5;

    /// @dev `P` — the standing nudge pot, denominated in the payment token.
    uint256 internal constant NUDGE_FUNDED_AMOUNT = 50_000 ether;
    uint256 internal constant POT_B = 1_234 ether;

    /// @dev Mirrors `BatchNFTMinterMultiToken.DUST_THRESHOLD` (internal there).
    uint256 internal constant DUST_THRESHOLD = 1e6;

    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);

    function setUp() public {
        batch = new BatchNFTMinterMultiToken(owner);
        nftMinter = new MockITokenMinterV2();
        nft = new MockERC1155();

        payToken = new MockERC20("PayToken", "PAY");
        rewardB = new MockERC20("RewardB", "RWB");
        bootToken = new MockERC20("BootToken", "BOOT");

        dispatcher = new MockTokenDispatcherV2(address(bootToken));

        nftMinter.setStakedToken(nft);
        nftMinter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(bootToken));
        nftMinter.setDispatcher(DISPATCHER_INDEX, address(dispatcher));

        vm.startPrank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        batch.setDispatcherIndex(DISPATCHER_INDEX);
        batch.setNudgeSize(NUDGE_SIZE);
        batch.setNudgeTokenWhitelist(address(payToken), true);
        batch.setNudgeTokenWhitelist(address(rewardB), true);
        vm.stopPrank();

        // The owner repoints the dispatcher: `payToken` is now the DERIVED
        // payment token as well as whitelist slot 0. Before story 029 this
        // combination silently skipped slot 0 and leaked the pot through the
        // step-10 balance sweep.
        dispatcher.setPrimeToken(address(payToken));
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
    }

    // ---------------------------------------------------------------- //
    // helpers
    // ---------------------------------------------------------------- //

    /// @dev Cumulative charge for `count` mints starting at `startPrice`, using
    ///      the minter's own ramp term for term.
    function _cumulative(uint256 startPrice, uint256 count) internal pure returns (uint256 total) {
        uint256 price = startPrice;
        for (uint256 i; i < count; ++i) {
            total += price;
            price = price + (price * GROWTH_BPS) / 10000;
        }
    }

    /// @dev Cumulative charge for `count` mints from the mock's CURRENT price.
    function _costNow(uint256 count) internal view returns (uint256) {
        return _cumulative(nftMinter.getPrice(DISPATCHER_INDEX), count);
    }

    /// @dev The price the `i`-th mint (0-based) of the NEXT batch will charge.
    function _priceAt(uint256 i) internal view returns (uint256 price) {
        price = nftMinter.getPrice(DISPATCHER_INDEX);
        for (uint256 k; k < i; ++k) {
            price = price + (price * GROWTH_BPS) / 10000;
        }
    }

    function _fundCaller(uint256 amount) internal {
        payToken.mint(caller, amount);
        vm.prank(caller);
        payToken.approve(address(batch), amount);
    }

    function _fundPots() internal {
        payToken.mint(address(batch), NUDGE_FUNDED_AMOUNT);
        rewardB.mint(address(batch), POT_B);
    }

    function _mins(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _mins(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    // ================================================================ //
    // Core properties (plan §8.2 - §8.4)
    // ================================================================ //

    /// @dev §8.2. The refund is EXACTLY the unspent budget — `A - C` — on a
    ///      ramping-price dispatcher, and the pot delta is all-or-nothing:
    ///      `0` for a non-qualifying batch, `-P` for a qualifying one. Never
    ///      partial, and never a function of the contract's balance.
    ///
    ///      Pre-change this fails on the first arm already: the step-10 sweep
    ///      hands `P + (A - C)` to `msg.sender`.
    function test_RefundEqualsUnspentBudgetExactly() public {
        _fundPots();
        uint256 surplus = 777 ether;

        // ---- arm 1: NON-QUALIFYING. Pot delta must be exactly 0. ----
        uint256 count1 = NUDGE_SIZE - 1;
        uint256 cost1 = _costNow(count1);
        uint256 a1 = cost1 + surplus;
        _fundCaller(a1);
        uint256 callerBefore = payToken.balanceOf(caller);
        uint256 potBefore = payToken.balanceOf(address(batch));

        vm.prank(caller);
        uint256 totalPaid1 = batch.batchMint(count1, recipient, a1, _mins(0, 0));

        assertEq(
            payToken.balanceOf(caller), callerBefore - cost1, "refund must equal paymentAmount - sum(prices) EXACTLY"
        );
        assertEq(totalPaid1, cost1, "totalPaid is the cumulative charge, nothing else");
        assertEq(payToken.balanceOf(address(batch)), potBefore, "pot delta must be 0 for a non-qualifying batch");
        assertEq(payToken.balanceOf(recipient), 0, "non-qualifying batch is paid no nudge");
        assertEq(rewardB.balanceOf(address(batch)), POT_B, "the non-colliding pot is equally untouched");

        // ---- arm 2: QUALIFYING. Pot delta must be exactly -P. ----
        uint256 cost2 = _costNow(NUDGE_SIZE); // the price has ramped under us
        uint256 a2 = cost2 + surplus;
        _fundCaller(a2);
        callerBefore = payToken.balanceOf(caller);
        potBefore = payToken.balanceOf(address(batch));

        vm.prank(caller);
        uint256 totalPaid2 = batch.batchMint(NUDGE_SIZE, recipient, a2, _mins(0, 0));

        assertEq(payToken.balanceOf(caller), callerBefore - cost2, "refund is still EXACTLY the unspent budget");
        assertEq(totalPaid2, cost2, "totalPaid unaffected by the payout");
        assertEq(payToken.balanceOf(recipient), potBefore, "pot delta must be exactly -P");
        assertEq(payToken.balanceOf(address(batch)), 0, "nothing left over: P paid out, A - C refunded");
        assertEq(rewardB.balanceOf(recipient), POT_B, "the non-colliding pot pays out alongside it");
    }

    /// @dev §8.3. Pins §3.2 — the runtime payment-token SKIP is gone, so the
    ///      payment token is paid out through the normal reward path like every
    ///      other whitelisted token, `NudgePaid` included.
    function test_PaymentTokenAsNudge_qualifyingBatchIsPaidThePot() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fundCaller(cost);

        vm.expectEmit(true, true, false, true, address(batch));
        emit NudgePaid(recipient, address(payToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(
            payToken.balanceOf(recipient),
            NUDGE_FUNDED_AMOUNT,
            "the payment token pays out through _payRewards like any other whitelisted token"
        );
        assertEq(payToken.balanceOf(address(batch)), 0, "pot fully delivered");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "and the real mints were paid for");
    }

    /// @dev The other half of §3.2: because the entry is no longer skipped, its
    ///      `minRewards[i]` floor is LIVE rather than silently ignored — a
    ///      strict improvement, and the reason the `minRewards` parameter's
    ///      NatSpec loses its "whose floor is ignored" clause.
    function test_PaymentTokenEntryFloorIsLive() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fundCaller(cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector,
                address(payToken),
                NUDGE_FUNDED_AMOUNT + 1,
                NUDGE_FUNDED_AMOUNT
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(NUDGE_FUNDED_AMOUNT + 1, 0));

        assertEq(payToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "floor breach rolled the batch back");
    }

    /// @dev §8.4. The §4.2 donate-forward property, extended to the colliding
    ///      token: `D` arrives AFTER the snapshot and is not part of `budget`,
    ///      so it is neither refunded to the batcher nor paid to `recipient` —
    ///      it stays behind to seed the next claimant, exactly as for every
    ///      other whitelisted token.
    function test_OwnDonationsDoNotRefundToBatcher_paymentTokenArm() public {
        _fundPots();

        uint256 donation = 3 ether;
        uint256 d = donation * NUDGE_SIZE;
        payToken.mint(address(nftMinter), d);
        nftMinter.setPerMintDonation(address(payToken), donation);

        uint256 cost = _costNow(NUDGE_SIZE);
        _fundCaller(cost);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(
            payToken.balanceOf(recipient),
            NUDGE_FUNDED_AMOUNT,
            unicode"§4.2: payout must equal the PRE-LOOP pot exactly, excluding this batch's own donations"
        );
        assertEq(
            payToken.balanceOf(address(batch)),
            d,
            unicode"§4.2: this batch's own donations must REMAIN in the contract to seed the next claimant"
        );
        assertEq(
            payToken.balanceOf(caller),
            callerBefore - cost,
            unicode"§4.2: donations must NOT be refunded to the batcher — the refund is budget-sourced, not balance-sourced"
        );
        assertEq(totalPaid, cost, "totalPaid is the cumulative charge");
    }

    // ================================================================ //
    // Token-behaviour independence (plan §8.7 - §8.9)
    // ================================================================ //

    /// @dev A fresh, isolated stack whose payment token is `prime` AND has
    ///      `prime` on the nudge whitelist. The whitelist write happens while
    ///      the dispatcher still points at `bootToken`, then the dispatcher is
    ///      repointed — the production route into the collision.
    struct Stack {
        BatchNFTMinterMultiToken batch;
        MockITokenMinterV2 minter;
        MockTokenDispatcherV2 disp;
        MockERC1155 nft;
    }

    function _isolatedStack(address prime) internal returns (Stack memory s) {
        s.minter = new MockITokenMinterV2();
        s.nft = new MockERC1155();
        s.disp = new MockTokenDispatcherV2(address(bootToken));
        s.batch = new BatchNFTMinterMultiToken(owner);

        s.minter.setStakedToken(s.nft);
        s.minter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        s.minter.setPrimeToken(DISPATCHER_INDEX, prime);
        s.minter.setDispatcher(DISPATCHER_INDEX, address(s.disp));

        vm.startPrank(owner);
        s.batch.setTokenMinter(ITokenMinterV2(address(s.minter)));
        s.batch.setDispatcherIndex(DISPATCHER_INDEX);
        s.batch.setNudgeSize(NUDGE_SIZE);
        s.batch.setNudgeTokenWhitelist(prime, true);
        vm.stopPrank();

        s.disp.setPrimeToken(prime);
    }

    /// @dev Fund a pot and a caller on `s`, run one batch, and report the
    ///      refund actually delivered to `caller` plus `totalPaid`.
    function _runBatchOn(Stack memory s, address token, uint256 count, uint256 pot, uint256 surplus)
        internal
        returns (uint256 refundDelivered, uint256 totalPaid, uint256 allowanceOnExit)
    {
        if (pot != 0) IMintableERC20(token).mint(address(s.batch), pot);

        uint256 cost = _cumulative(START_PRICE, count);
        uint256 a = cost + surplus;
        IMintableERC20(token).mint(caller, a);

        uint256 before = IERC20(token).balanceOf(caller);
        vm.startPrank(caller);
        IERC20(token).approve(address(s.batch), a);
        totalPaid = s.batch.batchMint(count, recipient, a, _mins(0));
        vm.stopPrank();

        refundDelivered = IERC20(token).balanceOf(caller) + a - before;
        allowanceOnExit = IERC20(token).allowance(address(s.batch), address(s.minter));
    }

    /// @dev §8.7. THE test that would fail under an allowance-READING design,
    ///      and the reason the absolute-approval rule exists. With a token whose
    ///      `transferFrom` never consumes allowance, the refund must be
    ///      byte-identical to the well-behaved case, and the allowance must
    ///      still be zero on exit — the final `forceApprove(minter, 0)` is
    ///      absolute, so it corrects whatever the last mint left standing.
    function test_NonDecrementingAllowanceToken_refundUnaffected() public {
        uint256 count = NUDGE_SIZE - 1; // non-qualifying: isolate the refund
        uint256 pot = 10_000 ether;
        uint256 surplus = 500 ether;

        MockERC20 wellBehaved = new MockERC20("Good", "GOOD");
        Stack memory good = _isolatedStack(address(wellBehaved));
        (uint256 refundGood, uint256 paidGood, uint256 allowGood) =
            _runBatchOn(good, address(wellBehaved), count, pot, surplus);

        MockNonDecrementingAllowanceERC20 weird = new MockNonDecrementingAllowanceERC20("Weird", "WRD");
        Stack memory odd = _isolatedStack(address(weird));
        (uint256 refundWeird, uint256 paidWeird, uint256 allowWeird) =
            _runBatchOn(odd, address(weird), count, pot, surplus);

        assertEq(refundGood, surplus, "control: refund is exactly the unspent budget");
        assertEq(
            refundWeird,
            refundGood,
            "refund must be IDENTICAL for a token that never decrements allowance; the budget is tracked locally, never read back from allowance()"
        );
        assertEq(paidWeird, paidGood, "totalPaid identical too");
        assertEq(allowGood, 0, "control: allowance revoked on exit");
        assertEq(
            allowWeird, 0, "allowance zeroed on exit even though transferFrom never consumed it (absolute forceApprove)"
        );
        assertEq(wellBehaved.balanceOf(address(good.batch)), pot, "control: pot intact");
        assertEq(weird.balanceOf(address(odd.batch)), pot, "pot intact for the odd token too");
    }

    /// @dev §8.8. The allowance granted to the minter is an ABSOLUTE per-mint
    ///      amount, never a delta and never unbounded: at the head of mint `i`
    ///      it is exactly the price mint `i` is about to charge, and it is zero
    ///      after the loop. Pre-change this observed `type(uint256).max` on
    ///      every iteration, which is what let an under-funded batch draw on the
    ///      contract's own balance.
    function test_ApprovalIsAbsoluteNotDelta() public {
        MockAllowanceRecordingMinterV2 rec = new MockAllowanceRecordingMinterV2();
        MockERC1155 recNft = new MockERC1155();
        MockTokenDispatcherV2 recDisp = new MockTokenDispatcherV2(address(bootToken));
        BatchNFTMinterMultiToken recBatch = new BatchNFTMinterMultiToken(owner);

        rec.setStakedToken(recNft);
        rec.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        rec.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        rec.setDispatcher(DISPATCHER_INDEX, address(recDisp));

        vm.startPrank(owner);
        recBatch.setTokenMinter(ITokenMinterV2(address(rec)));
        recBatch.setDispatcherIndex(DISPATCHER_INDEX);
        recBatch.setNudgeSize(NUDGE_SIZE);
        recBatch.setNudgeTokenWhitelist(address(payToken), true);
        vm.stopPrank();
        recDisp.setPrimeToken(address(payToken));

        // A fat pot, so an unbounded allowance would have plenty to eat.
        payToken.mint(address(recBatch), NUDGE_FUNDED_AMOUNT);

        uint256 count = 6;
        uint256 cost = _cumulative(START_PRICE, count);
        payToken.mint(caller, cost);
        vm.startPrank(caller);
        payToken.approve(address(recBatch), cost);
        recBatch.batchMint(count, recipient, cost, _mins(0));
        vm.stopPrank();

        assertEq(rec.observedAllowanceCount(), count, "one observation per mint");

        uint256 price = START_PRICE;
        for (uint256 i; i < count; ++i) {
            assertEq(
                rec.observedAllowanceAt(i),
                price,
                "allowance at the head of each mint must be EXACTLY that mint's price: not max, not a running remainder"
            );
            assertEq(rec.chargedPriceAt(i), price, "and that price is what the mint actually charged");
            price = price + (price * GROWTH_BPS) / 10000;
        }

        assertEq(payToken.allowance(address(recBatch), address(rec)), 0, "allowance revoked after the loop");
        assertEq(payToken.balanceOf(recipient), NUDGE_FUNDED_AMOUNT, "and the pot was paid, not eaten by the mints");
    }

    /// @dev §8.9, first arm. With a fee-on-transfer payment token the contract
    ///      is credited less than `paymentAmount`, and the refund is the
    ///      CREDITED budget — measured across the step-5 pull — not the quoted
    ///      one. Nothing reverts and the caller gets back exactly what of their
    ///      money survived the pull and the mints.
    ///
    ///      The pot is held in a SECOND whitelisted token here, so this arm says
    ///      nothing about pot integrity under a taxed token; that is
    ///      `test_FeeOnTransferPaymentToken_potIsUntouchedWhenItHoldsThePot`
    ///      below, which puts the tax and the pot in the SAME asset. Before the
    ///      credited-delta measurement, `budget` was the quoted `paymentAmount`
    ///      and the `available` cap was the only thing standing between the
    ///      shortfall and the pot — which is why this arm's numbers are
    ///      unchanged while that one's are not.
    ///
    ///      `available` is now belt-and-braces: it is asserted here to be
    ///      NON-BINDING, i.e. the refund is sourced from the measured budget and
    ///      the cap never has to lower it.
    function test_FeeOnTransferPaymentToken_refundIsTheCreditedBudget() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", feeBps);
        Stack memory s = _isolatedStack(address(taxed));

        vm.prank(owner);
        s.batch.setNudgeTokenWhitelist(address(rewardB), true);
        rewardB.mint(address(s.batch), POT_B);

        uint256 count = NUDGE_SIZE - 1; // non-qualifying: pot must not move at all
        uint256 cost = _cumulative(START_PRICE, count);
        uint256 surplus = 1_000 ether;
        uint256 a = cost + surplus;

        taxed.mint(caller, a);
        uint256 before = taxed.balanceOf(caller);
        vm.startPrank(caller);
        taxed.approve(address(s.batch), a);
        uint256 totalPaid = s.batch.batchMint(count, recipient, a, _mins(0, 0));
        vm.stopPrank();

        // The caller's money that actually arrived, less what the mints charged.
        uint256 creditedSurplus = a - (a * feeBps) / 10_000 - cost;

        assertLt(creditedSurplus, surplus, "precondition: the fee really did shrink the caller's credited budget");
        assertEq(totalPaid, a - creditedSurplus, "the refund is the credited budget, not the quoted one");
        assertEq(
            taxed.balanceOf(caller) + a - before,
            creditedSurplus - (creditedSurplus * feeBps) / 10_000,
            "caller receives the credited surplus, less the fee on the refund transfer itself"
        );
        assertEq(taxed.balanceOf(address(s.batch)), 0, "everything the caller was credited and did not spend went back");
        assertEq(rewardB.balanceOf(address(s.batch)), POT_B, "the SECOND token's pot is untouched (see note above)");
        assertEq(rewardB.balanceOf(recipient), 0, "and nothing was paid out for a non-qualifying batch");
    }

    // ================================================================ //
    // The budget is MEASURED, not trusted (review finding A)
    // ================================================================ //

    /// @dev The taxed token is the payment token AND holds the pot — the case
    ///      the arm above deliberately does not cover. `budget` is measured
    ///      across the step-5 pull, so the fee is charged to the caller's own
    ///      credit and the pot is not asked to make up the difference.
    ///
    ///      Pre-measurement this took `paymentAmount - cost` out of a balance
    ///      that only ever held `credited - cost` of the caller's money, so the
    ///      remainder came out of `P`: a non-qualifying batch shrank the pot by
    ///      the fee, repeatably, with the shortfall landing in the token's fee
    ///      sink. Griefing where the sink is a third party; direct extraction
    ///      where the attacker controls it — the "pot leaves without the caller
    ///      paying for `nudgeSize` real mints" carve-out of the 2026-07-25
    ///      arbitrage acceptance.
    function test_FeeOnTransferPaymentToken_potIsUntouchedWhenItHoldsThePot() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", feeBps);
        Stack memory s = _isolatedStack(address(taxed));

        uint256 pot = 10_000 ether;
        taxed.mint(address(s.batch), pot);
        // The mint is the zero-address branch, so the pot arrives untaxed.
        assertEq(taxed.balanceOf(address(s.batch)), pot, "fixture: the pot is P exactly");

        uint256 count = NUDGE_SIZE - 1; // non-qualifying: the pot must not move AT ALL
        uint256 cost = _cumulative(START_PRICE, count);
        uint256 a = cost + 1_000 ether;
        uint256 credited = a - (a * feeBps) / 10_000;

        taxed.mint(caller, a);
        uint256 callerBefore = taxed.balanceOf(caller);
        uint256 sinkBefore = taxed.balanceOf(taxed.FEE_SINK());

        vm.startPrank(caller);
        taxed.approve(address(s.batch), a);
        uint256 totalPaid = s.batch.batchMint(count, recipient, a, _mins(0));
        vm.stopPrank();

        uint256 refund = credited - cost;

        assertEq(
            taxed.balanceOf(address(s.batch)),
            pot,
            "POT INTEGRITY: a non-qualifying batch leaves P EXACTLY where it was, taxed token or not"
        );
        assertEq(totalPaid, a - refund, "totalPaid is the quoted amount less the measured refund");
        assertEq(
            taxed.balanceOf(caller),
            callerBefore - a + (refund - (refund * feeBps) / 10_000),
            "the caller alone bears the token's fee on their own money"
        );
        assertGt(taxed.balanceOf(taxed.FEE_SINK()), sinkBefore, "the fee sink was fed, but only out of the caller");
        assertEq(taxed.balanceOf(recipient), 0, "non-qualifying: nothing paid out");
    }

    /// @dev The inverted second arm of the same defect. With the shortfall taken
    ///      out of the pot, a QUALIFYING batch in this configuration cannot pay
    ///      the snapshot it captured — `_payRewards` reverts on the balance and
    ///      the whole batch rolls back, so the taxed-payment-token config was
    ///      not merely leaky, it was bricked at `count >= nudgeSize`.
    ///
    ///      Measuring the budget restores it: after the refund the contract
    ///      holds exactly `P`, which is exactly what the snapshot promised.
    function test_FeeOnTransferPaymentToken_qualifyingBatchStillPaysThePot() public {
        uint256 feeBps = 500; // 5%
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", feeBps);
        Stack memory s = _isolatedStack(address(taxed));

        uint256 pot = 10_000 ether;
        taxed.mint(address(s.batch), pot);

        uint256 count = NUDGE_SIZE; // qualifying
        uint256 cost = _cumulative(START_PRICE, count);
        uint256 a = cost + 1_000 ether;

        taxed.mint(caller, a);
        vm.startPrank(caller);
        taxed.approve(address(s.batch), a);
        s.batch.batchMint(count, recipient, a, _mins(0));
        vm.stopPrank();

        assertEq(
            taxed.balanceOf(recipient),
            pot - (pot * feeBps) / 10_000,
            "the qualifying batch is paid the WHOLE pot; only the token's own fee is deducted in flight"
        );
        assertEq(taxed.balanceOf(address(s.batch)), 0, "P paid out, credited surplus refunded, nothing stranded");
    }

    /// @dev The measurement is a CEILING at `paymentAmount`, never a floor.
    ///
    ///      `budget = balanceAfter - balanceBefore` alone is unbounded above: a
    ///      token with a transfer callback lets a third party push funds into
    ///      this contract DURING the pull, and `nonReentrant` does not stop it
    ///      (it blocks re-entering `batchMint`, not an inbound transfer). Those
    ///      funds would land inside the measurement window and be refundable to
    ///      `msg.sender` — donate-forward `D` re-routed to the batcher, which is
    ///      the `ycn19h1` mechanism reached through a narrower door.
    ///
    ///      `min(credited, paymentAmount)` takes the tighter of measured and
    ///      quoted, so the donation stays behind for the next claimant exactly
    ///      as a donation arriving during the mint loop does.
    function test_DonationDuringPullCannotInflateBudget() public {
        MockDonatingOnPullERC20 hooked = new MockDonatingOnPullERC20("Hooked", "HOOK");
        Stack memory s = _isolatedStack(address(hooked));

        address benefactor = makeAddr("benefactor");
        uint256 donation = 4_321 ether;
        hooked.mint(benefactor, donation);
        hooked.setDonation(benefactor, donation);

        uint256 count = NUDGE_SIZE - 1; // non-qualifying, so nothing legitimately leaves
        uint256 cost = _cumulative(START_PRICE, count);
        uint256 surplus = 500 ether;
        uint256 a = cost + surplus;

        hooked.mint(caller, a);
        uint256 callerBefore = hooked.balanceOf(caller);

        vm.startPrank(caller);
        hooked.approve(address(s.batch), a);
        uint256 totalPaid = s.batch.batchMint(count, recipient, a, _mins(0));
        vm.stopPrank();

        assertEq(
            hooked.balanceOf(caller),
            callerBefore - cost,
            "the caller gets back their OWN unspent budget and not one wei of the benefactor's"
        );
        assertEq(totalPaid, cost, "totalPaid is unaffected by money that was never theirs");
        assertEq(
            hooked.balanceOf(address(s.batch)),
            donation,
            "the donation stays behind for the next qualifying claimant, like any other donate-forward"
        );
        assertEq(hooked.balanceOf(recipient), 0, "non-qualifying: no payout");
    }

    /// @dev The SECOND, less obvious obligation of the SAME `min`: it is what
    ///      keeps `totalPaid = paymentAmount - refund` in step 9 from
    ///      underflowing.
    ///
    ///      That subtraction is BARE. At `d75229d` it read
    ///      `paymentAmount > remaining ? paymentAmount - remaining : 0`; story
    ///      029 removed the guard deliberately, and commit `0318089` §3.3 names
    ///      its ABSENCE as the marker of the fix. The removal is safe SOLELY
    ///      because `refund <= budget <= paymentAmount`, and the right-hand
    ///      inequality is established by the step-5 `min` and nowhere else.
    ///
    ///      This test does NOT close a coverage gap, and it must not be
    ///      described as one. `test_DonationDuringPullCannotInflateBudget`
    ///      above already stages `donation = 4_321 ether` against a cumulative
    ///      charge of `4152.515625 ether`, so it too trips obligation 2:
    ///      substituting `budget = credited` for the step-5 `min` makes BOTH
    ///      tests panic `0x11`, verified. What that test does not do is SAY so
    ///      — it is named, documented and asserted entirely in terms of
    ///      donation routing, and its `donation > cost` relation is incidental
    ///      to its fixture rather than a stated requirement of it. Someone
    ///      retuning that fixture could drop below the charge without noticing
    ///      they had also dropped the underflow coverage.
    ///
    ///      This test makes the incidental property explicit, named and
    ///      greppable, so the obligation survives a future edit to either
    ///      test. It asserts `donation > cost` as a `TRIPWIRE:` precondition
    ///      rather than leaving it to arithmetic a reader has to redo. With
    ///      the cap removed, the counterfactual refund is
    ///      `paymentAmount + donation - cost`, which exceeds `paymentAmount`
    ///      exactly when `donation > cost`, and step 9 reverts with an
    ///      arithmetic underflow instead of returning. A future author who
    ///      relaxes the cap to a floor, or substitutes the measured `credited`
    ///      on the grounds that measuring is strictly more honest, turns every
    ///      such batch into an unconditional DoS.
    function test_MinIsLoadBearing_totalPaidCannotUnderflow() public {
        MockDonatingOnPullERC20 hooked = new MockDonatingOnPullERC20("Hooked", "HOOK");
        Stack memory s = _isolatedStack(address(hooked));

        uint256 count = NUDGE_SIZE - 1; // non-qualifying: no payout to confound the arithmetic
        uint256 cost = _cumulative(START_PRICE, count);
        uint256 surplus = 500 ether;
        uint256 paymentAmount = cost + surplus;

        // The donation must EXCEED the cumulative charge — that is precisely
        // the condition under which an uncapped `credited` drives the refund
        // past `paymentAmount`.
        uint256 donation = cost * 3;
        address benefactor = makeAddr("underflowBenefactor");
        hooked.mint(benefactor, donation);
        hooked.setDonation(benefactor, donation);

        // TRIPWIRE: the donation really is larger than the charge, so this
        // fixture really does stage the underflow and not a milder shape.
        assertGt(donation, cost, "TRIPWIRE: donation must exceed the cumulative charge to stage the underflow");

        // TRIPWIRE: the counterfactual — `budget` taken as the measured
        // `credited`, uncapped — really would make step 9 subtract more than
        // `paymentAmount`. This is the arithmetic the `min` is preventing.
        uint256 uncappedRefund = (paymentAmount + donation) - cost;
        assertGt(
            uncappedRefund, paymentAmount, "TRIPWIRE: without the min, step 9 would subtract more than paymentAmount"
        );

        hooked.mint(caller, paymentAmount);
        uint256 callerBefore = hooked.balanceOf(caller);

        vm.startPrank(caller);
        hooked.approve(address(s.batch), paymentAmount);
        // Does NOT revert: the `min` clamps `budget` to `paymentAmount`, so the
        // bare subtraction below stays in range.
        uint256 totalPaid = s.batch.batchMint(count, recipient, paymentAmount, _mins(0));
        vm.stopPrank();

        uint256 refundDelivered = hooked.balanceOf(caller) + paymentAmount - callerBefore;

        assertLe(refundDelivered, paymentAmount, "refund <= paymentAmount is what makes the bare subtraction safe");
        assertEq(refundDelivered, surplus, "the refund is the caller's own unspent budget, not the benefactor's money");
        assertEq(
            totalPaid, paymentAmount - refundDelivered, "totalPaid is the bare subtraction, evaluated without underflow"
        );
        assertEq(totalPaid, cost, "and it equals the cumulative charge");
        assertEq(
            hooked.balanceOf(address(s.batch)), donation, "the over-large donation stays behind as pot, uncredited"
        );
        assertEq(hooked.balanceOf(recipient), 0, "non-qualifying: no payout");
    }

    // ================================================================ //
    // Boundaries (plan §8.10 - §8.11)
    // ================================================================ //

    /// @dev §8.10a. A cumulative charge EXACTLY equal to `paymentAmount`
    ///      succeeds, refunds nothing, and still pays the pot in full.
    function test_CumulativeChargeExactlyEqualToPaymentAmountSucceeds() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fundCaller(cost);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(totalPaid, cost, "exact budget: totalPaid is the whole paymentAmount");
        assertEq(payToken.balanceOf(caller), callerBefore - cost, "nothing refunded, nothing extra taken");
        assertEq(payToken.balanceOf(recipient), NUDGE_FUNDED_AMOUNT, "the pot is still paid in full");
        assertEq(payToken.balanceOf(address(batch)), 0, "and the contract is left exactly empty");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "all mints landed");
    }

    /// @dev §8.10b. One wei short reverts at the CORRECT mint index, naming that
    ///      mint's price and the budget remaining at that point. With a ramping
    ///      price the shortfall surfaces on the LAST mint, not the first — the
    ///      error would be useless if it did not say which.
    function test_RevertWhen_OneWeiShortRevertsAtCorrectMintIndex() public {
        _fundPots();
        uint256 count = NUDGE_SIZE;
        uint256 cost = _costNow(count);
        uint256 lastPrice = _priceAt(count - 1);
        uint256 spentBeforeLast = _cumulative(nftMinter.getPrice(DISPATCHER_INDEX), count - 1);

        _fundCaller(cost - 1);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__PaymentBudgetExhausted.selector,
                count - 1,
                lastPrice,
                (cost - 1) - spentBeforeLast
            )
        );
        batch.batchMint(count, recipient, cost - 1, _mins(0, 0));

        assertEq((cost - 1) - spentBeforeLast, lastPrice - 1, "sanity: the shortfall really is one wei");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "atomic rollback: nothing minted");
        assertEq(payToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "pot untouched");
        assertEq(payToken.balanceOf(caller), cost - 1, "caller's funds untouched");
    }

    /// @dev §8.10c. The first mint is the failing index when the caller cannot
    ///      even afford one. This is the `ycn19h1` shape, reduced to arithmetic:
    ///      one wei of budget against a fat pot.
    function test_RevertWhen_BudgetCannotCoverTheFirstMint() public {
        _fundPots();
        uint256 price0 = _priceAt(0);
        _fundCaller(1);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterMultiToken.BatchMint__PaymentBudgetExhausted.selector, 0, price0, 1)
        );
        batch.batchMint(1, recipient, 1, _mins(0, 0));

        assertEq(payToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "the pot cannot top up an empty budget");
    }

    /// @dev §8.11. Ramping-price control. A front-end that quotes the flat
    ///      `count * startPrice` under-quotes on a `growthBasisPoints > 0`
    ///      dispatcher and now reverts LOUDLY at the first mint it cannot fund,
    ///      instead of silently drawing the difference out of the contract's
    ///      balance. Passing the true cumulative amount plus a surplus succeeds
    ///      and returns exactly the surplus.
    function test_RampingPriceControl_naiveFlatQuoteRevertsAndSurplusIsReturned() public {
        _fundPots();
        uint256 count = NUDGE_SIZE;
        uint256 startPrice = nftMinter.getPrice(DISPATCHER_INDEX);
        uint256 trueCost = _costNow(count);
        uint256 flatQuote = startPrice * count;
        assertLt(flatQuote, trueCost, "precondition: the flat quote really does under-quote a ramping dispatcher");

        // Find the index the flat quote cannot fund.
        uint256 failingIndex;
        uint256 spent;
        while (spent + _priceAt(failingIndex) <= flatQuote) {
            spent += _priceAt(failingIndex);
            ++failingIndex;
        }

        // Resolve every expected value BEFORE the prank: `_priceAt` makes an
        // external `getPrice` call, which would consume the prank if it were
        // evaluated as an argument inside `vm.expectRevert(...)`.
        uint256 failingPrice = _priceAt(failingIndex);
        uint256 remainingAtFailure = flatQuote - spent;

        _fundCaller(flatQuote);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__PaymentBudgetExhausted.selector,
                failingIndex,
                failingPrice,
                remainingAtFailure
            )
        );
        batch.batchMint(count, recipient, flatQuote, _mins(0, 0));
        assertEq(payToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "under-quote moved nothing");

        // The honest cumulative quote plus a surplus: succeeds, surplus returned.
        uint256 surplus = 3 ether;
        _fundCaller(trueCost + surplus);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(count, recipient, trueCost + surplus, _mins(0, 0));

        assertEq(totalPaid, trueCost, "totalPaid is the true ramping cumulative cost");
        assertEq(payToken.balanceOf(caller), callerBefore - trueCost, "the surplus, and only the surplus, came back");
        assertEq(payToken.balanceOf(recipient), NUDGE_FUNDED_AMOUNT, "pot paid to the recipient");
    }
}
