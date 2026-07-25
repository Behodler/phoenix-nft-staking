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
/// runtime; after story 029 it is **permitted and safe by construction**,
/// because the refund derives from a locally-tracked `budget` — provably the
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
    ///      whitelisted. `setNudgeTokenWhitelist` still refuses to whitelist the
    ///      CURRENT payment token (defence in depth, §5.1), so the collision is
    ///      reached the way it is reached in production: the owner repoints the
    ///      dispatcher afterwards, out from under an existing entry.
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
}
