// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockReentrantERC20} from "./mocks/MockReentrantERC20.sol";

/// @title BatchNFTMinterMultiToken — whitelist-selected multi-token nudge
///
/// The §4 invariant suite from `docs/multi-token-nudge.md`, re-targeted for
/// the story-025 whitelist model. The owner controls ELIGIBILITY
/// (`nudgeSize`) and the SET of nudge-reward tokens (an owner-managed
/// whitelist, `setNudgeTokenWhitelist`); the caller supplies only the
/// per-token `minRewards` floors, ordered to match `getNudgeTokens()`.
///
/// The suite is organised by the invariant each group pins:
///   §4.1  payment token AS a nudge token: permitted and safe (story-029)
///   §4.2  snapshot BEFORE the mint loop ("donate forward")
///   §4.3  reentrancy guard
///   §4.4  fee-on-transfer is documented, not defended
///   §4.5  duplicates are structurally impossible (set semantics)
contract BatchNFTMinterMultiTokenNudgeTest is Test {
    BatchNFTMinterMultiToken internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;

    MockERC20 internal payToken;
    MockERC20 internal rewardA; // "USDC"
    MockERC20 internal rewardB; // "WBTC"
    MockERC20 internal rewardC; // present on the contract, never whitelisted

    address internal owner = makeAddr("batchOwner");
    address internal caller = makeAddr("batchCaller");
    address internal caller2 = makeAddr("batchCaller2");
    address internal recipient = makeAddr("batchRecipient");

    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250; // 2.5% per mint

    uint256 internal constant NUDGE_SIZE = 5;
    uint256 internal constant POT_A = 100_000e6;
    uint256 internal constant POT_B = 1_00000000;
    uint256 internal constant POT_C = 7_777 ether;

    /// @dev Mirrors `BatchNFTMinterMultiToken.DUST_THRESHOLD` (internal there).
    uint256 internal constant DUST_THRESHOLD = 1e6;

    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event NudgeTokenWhitelistChanged(address indexed token, bool allowed);

    function setUp() public {
        batch = new BatchNFTMinterMultiToken(owner);
        nftMinter = new MockITokenMinterV2();
        nft = new MockERC1155();

        payToken = new MockERC20("PayToken", "PAY");
        rewardA = new MockERC20("RewardA", "RWA");
        rewardB = new MockERC20("RewardB", "RWB");
        rewardC = new MockERC20("RewardC", "RWC");

        dispatcher = new MockTokenDispatcherV2(address(payToken));

        nftMinter.setStakedToken(nft);
        nftMinter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        nftMinter.setDispatcher(DISPATCHER_INDEX, address(dispatcher));

        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        vm.prank(owner);
        batch.setDispatcherIndex(DISPATCHER_INDEX);
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
    }

    // ---------------------------------------------------------------- //
    // helpers
    // ---------------------------------------------------------------- //

    function _expectedTotal(uint256 startPrice, uint256 growthBps, uint256 count)
        internal
        pure
        returns (uint256 total)
    {
        uint256 price = startPrice;
        for (uint256 i = 0; i < count; i++) {
            total += price;
            price = (price * (10_000 + growthBps)) / 10_000;
        }
    }

    /// @dev Cost of `count` mints starting from the mock's CURRENT price.
    function _costNow(uint256 count) internal view returns (uint256) {
        return _expectedTotal(nftMinter.getPrice(DISPATCHER_INDEX), GROWTH_BPS, count);
    }

    function _fund(address who, uint256 amount) internal {
        payToken.mint(who, amount);
        vm.prank(who);
        payToken.approve(address(batch), amount);
    }

    function _fundPots() internal {
        rewardA.mint(address(batch), POT_A);
        rewardB.mint(address(batch), POT_B);
        rewardC.mint(address(batch), POT_C);
    }

    /// @dev Owner-whitelist a nudge token.
    function _whitelist(address token) internal {
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(token, true);
    }

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _arr(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
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

    function _mins(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _noMins() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // ================================================================ //
    // §4.1 — payment token AS a nudge token: permitted and SAFE (story-029)
    //
    // This group used to pin a two-part "payment-token exclusion": an
    // admin-time revert plus a runtime SKIP in the snapshot loop. The runtime
    // half was falsified by yield-claim-nft submission `ycn19h1` — skipping the
    // entry kept the payment token out of the PAYOUT but not out of the
    // step-10 balance sweep, so the whole nudge pot left to any `count = 1`
    // caller who paid one wei. The skip is gone. The payment token is now
    // snapshotted, floor-checked and paid out like every other whitelisted
    // token, and the refund derives from a tracked `budget` instead of a
    // balance, which is what makes the collision safe rather than merely
    // forbidden.
    //
    // The admin-time revert has now gone as well (story-032), so the two-part
    // exclusion is FULLY gone: no runtime skip (029) and no admin-time revert
    // (032). The collision is reachable BOTH ways — a direct
    // `setNudgeTokenWhitelist(paymentToken, true)` call, and the production
    // route of repointing `tokenMinter`/`dispatcherIndex` out from under an
    // existing entry. Neither needs defending, because what keeps the pot safe
    // is the SOURCE of the refund: it is bounded by the caller's tracked
    // `budget`, so no amount of whitelist shape lets the pot leave that way.
    // ================================================================ //

    /// @dev 1. `setNudgeTokenWhitelist` accepts the CURRENT derived payment
    ///      token. The admin-time rejection story-025 introduced and story-029
    ///      demoted to defence in depth is deleted in story-032; the add branch
    ///      no longer derives the payment path at all. `batchMint` is safe with
    ///      the payment token on the whitelist (tests 2-4 below prove it), and
    ///      the owner could always reach the same state by repointing the
    ///      dispatcher. (The full admin-suite lives in
    ///      `BatchNFTMinterMultiTokenNudgeCore.t.sol`; this is the §4.1
    ///      anchor.)
    function test_WhitelistingPaymentTokenSucceeds() public {
        _whitelist(address(rewardA));

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgeTokenWhitelistChanged(address(payToken), true);
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(payToken), true);

        address[] memory tokens = batch.getNudgeTokens();
        assertEq(tokens.length, 2, "payment token lands on the whitelist");
        assertEq(tokens[1], address(payToken), "appended at the end, in storage order");
        assertTrue(batch.isNudgeToken(address(payToken)), "membership view agrees");
    }

    /// @dev 2. Runtime collision: the owner whitelists token A while the payment
    ///      token is P, then repoints the dispatcher so A BECOMES the derived
    ///      payment token. `batchMint` must neither brick NOR skip — A is
    ///      snapshotted before the caller's budget arrives (so the reading is the
    ///      uncontaminated pot), floor-checked, and PAID OUT to `recipient` like
    ///      every other whitelisted token. The caller receives only their unspent
    ///      budget, which here is zero.
    ///
    ///      This test previously asserted the opposite on both counts: that the
    ///      recipient got nothing and that A's pot swept back to `msg.sender`.
    ///      That was `ycn19h1`, written down as expected behaviour.
    function test_RuntimePaymentTokenCollisionIsPaidNotSkipped() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();

        // Owner repoints the dispatcher: rewardA is now the derived payment
        // token, out from under the existing whitelist entry.
        dispatcher.setPrimeToken(address(rewardA));
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(rewardA));

        uint256 cost = _costNow(NUDGE_SIZE);
        rewardA.mint(caller, cost);
        vm.prank(caller);
        rewardA.approve(address(batch), cost);
        uint256 callerABefore = rewardA.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(POT_A, POT_B));

        assertEq(rewardA.balanceOf(recipient), POT_A, "the colliding entry is PAID, not skipped");
        assertEq(rewardB.balanceOf(recipient), POT_B, "non-colliding entry still pays in full");
        assertEq(
            rewardA.balanceOf(caller),
            callerABefore - cost,
            "the pot is NOT the caller's money: they are charged the cumulative price and refunded nothing"
        );
        assertEq(rewardA.balanceOf(address(batch)), 0, "pot fully delivered to the recipient");
        assertEq(totalPaid, cost, "totalPaid is the cumulative charge");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "batch stays live under the collision");
    }

    /// @dev 2b. The colliding entry's `minRewards[i]` floor is LIVE, where the
    ///      skip used to ignore it entirely. An impossible floor on slot 0 now
    ///      reverts before anything is pulled — a strict improvement, and the
    ///      reason `batchMint`'s `minRewards` NatSpec loses its "whose floor is
    ///      ignored" clause.
    function test_RuntimePaymentTokenCollisionFloorIsLive() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();

        dispatcher.setPrimeToken(address(rewardA));
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(rewardA));

        uint256 cost = _costNow(NUDGE_SIZE);
        rewardA.mint(caller, cost);
        vm.prank(caller);
        rewardA.approve(address(batch), cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector,
                address(rewardA),
                type(uint256).max,
                POT_A
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(type(uint256).max, 0));

        assertEq(rewardA.balanceOf(address(batch)), POT_A, "floor breach rolled the whole batch back");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "nothing minted");
    }

    /// @dev 3. Below the threshold the colliding entry behaves exactly like
    ///      every other entry: snapshot pinned to `0`, nothing paid — and,
    ///      crucially, the pot STAYS. It used to sweep to `msg.sender`, which is
    ///      the `ycn19h1` extraction in its purest form (a non-qualifying batch
    ///      taking pot-sized value).
    function test_RuntimeCollisionBelowThresholdKeepsThePot() public {
        _whitelist(address(rewardA));
        _fundPots();

        dispatcher.setPrimeToken(address(rewardA));
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(rewardA));

        uint256 below = NUDGE_SIZE - 1;
        uint256 cost = _costNow(below);
        uint256 surplus = 5e6;
        rewardA.mint(caller, cost + surplus);
        vm.prank(caller);
        rewardA.approve(address(batch), cost + surplus);
        uint256 callerABefore = rewardA.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(below, recipient, cost + surplus, _mins(0));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), below, "sub-threshold batch minted under the collision");
        assertEq(rewardA.balanceOf(recipient), 0, "nothing paid below threshold");
        assertEq(
            rewardA.balanceOf(address(batch)),
            POT_A,
            "POT INTEGRITY: a non-qualifying batch must leave the pot exactly where it was"
        );
        assertEq(rewardA.balanceOf(caller), callerABefore - cost, "caller is refunded their surplus and nothing more");
        assertEq(totalPaid, cost, "totalPaid is the cumulative charge");
    }

    /// @dev 3b. Below the threshold the floor is live too: `available` is `0`
    ///      for every entry, so any non-zero floor reverts rather than being
    ///      silently ignored for the colliding slot.
    function test_RuntimeCollisionBelowThresholdFloorIsLive() public {
        _whitelist(address(rewardA));
        _fundPots();

        dispatcher.setPrimeToken(address(rewardA));
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(rewardA));

        uint256 below = NUDGE_SIZE - 1;
        uint256 cost = _costNow(below);
        rewardA.mint(caller, cost);
        vm.prank(caller);
        rewardA.approve(address(batch), cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardA), 1, 0
            )
        );
        batch.batchMint(below, recipient, cost, _mins(1));
    }

    /// @dev 4. Sub-threshold payment-token dust left by a prior batch is not
    ///      claimable by the NEXT caller either. It used to be swept out
    ///      alongside that caller's own surplus (`surplus + dust`); the refund is
    ///      now budget-sourced, so the caller gets back exactly their own
    ///      unspent budget and the dust stays behind as pot. Sub-threshold
    ///      residue accrues in the protocol's favour, which is what the
    ///      `DUST_THRESHOLD` floor was for all along.
    function test_PaymentTokenDustIsNotSweptIntoTheRefund() public {
        _whitelist(address(rewardA));
        _fundPots();

        // Batch 1 leaves sub-threshold dust behind.
        uint256 dust = DUST_THRESHOLD - 1;
        uint256 cost1 = _costNow(1);
        _fund(caller, cost1 + dust);
        vm.prank(caller);
        batch.batchMint(1, recipient, cost1 + dust, _mins(0));
        assertEq(payToken.balanceOf(address(batch)), dust, "sub-threshold dust retained");

        // `payToken` is deliberately NOT whitelisted here, so the dust is not a
        // nudge pot and cannot be paid out as a reward either. The only exit it
        // could plausibly take is the refund, and that is exactly what this test
        // denies. The whitelisted arm is
        // `test_PaymentTokenDustBecomesNudgePotWhenWhitelisted` below.
        //
        // A later batch with a supra-threshold surplus gets back its OWN unspent
        // budget and nothing else. The prior batch's dust is not part of that
        // budget, so it is left where it is.
        uint256 surplus = 5 ether;
        uint256 cost2 = _costNow(NUDGE_SIZE);
        _fund(caller2, cost2 + surplus);
        uint256 caller2Before = payToken.balanceOf(caller2);
        vm.prank(caller2);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost2 + surplus, _mins(0));

        assertEq(payToken.balanceOf(address(batch)), dust, "the prior batch's dust is NOT the next caller's money");
        assertEq(payToken.balanceOf(caller2), caller2Before - cost2, "caller receives exactly their own unspent budget");
        assertEq(totalPaid, cost2, "totalPaid is the cumulative charge, not net of someone else's dust");
    }

    /// @dev 4b. The story-032 arm of the same scenario. Once the owner
    ///      whitelists the payment token — which they may now do in a single
    ///      call — the retained dust stops being inert and becomes a live nudge
    ///      pot like any other whitelisted balance. It is paid to `recipient`,
    ///      NOT refunded to the caller: the two exits are separately sourced,
    ///      the payout from the pre-loop snapshot and the refund from the
    ///      caller's tracked `budget`. So the change of whitelist shape moves
    ///      the dust to the claimant, and never to the batcher.
    function test_PaymentTokenDustBecomesNudgePotWhenWhitelisted() public {
        _whitelist(address(rewardA));
        _fundPots();

        // Batch 1 leaves sub-threshold dust behind, exactly as above.
        uint256 dust = DUST_THRESHOLD - 1;
        uint256 cost1 = _costNow(1);
        _fund(caller, cost1 + dust);
        vm.prank(caller);
        batch.batchMint(1, recipient, cost1 + dust, _mins(0));
        assertEq(payToken.balanceOf(address(batch)), dust, "sub-threshold dust retained");

        // Story-032: the owner turns the dust into a nudge pot in ONE call.
        _whitelist(address(payToken));
        address[] memory tokens = batch.getNudgeTokens();
        assertEq(tokens[1], address(payToken), "payToken is whitelist slot 1");

        uint256 surplus = 5 ether;
        uint256 cost2 = _costNow(NUDGE_SIZE);
        _fund(caller2, cost2 + surplus);
        uint256 caller2Before = payToken.balanceOf(caller2);
        uint256 recipientBefore = payToken.balanceOf(recipient);

        vm.prank(caller2);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost2 + surplus, _mins(0, 0));

        assertEq(payToken.balanceOf(recipient), recipientBefore + dust, "the dust is PAID to the recipient as a nudge");
        assertEq(
            payToken.balanceOf(caller2),
            caller2Before - cost2,
            "caller still receives exactly their own unspent budget and nothing more"
        );
        assertEq(payToken.balanceOf(address(batch)), 0, "pot fully delivered; no payment-token residue");
        assertEq(rewardA.balanceOf(recipient), POT_A, "the non-colliding entry still pays in full");
        assertEq(totalPaid, cost2, "totalPaid is the cumulative charge");
    }

    // ================================================================ //
    // §4.2 — snapshot BEFORE the mint loop ("donate forward")
    // ================================================================ //

    /// @dev 5. THE load-bearing property. The dispatcher donates reward token
    ///      into this contract on every mint. Because the balance is read
    ///      BEFORE the mint loop, the batcher is paid exactly the PRIOR
    ///      accumulated pot; its own mid-loop donations stay behind to seed the
    ///      next claimant. A post-loop read would refund the batch's own
    ///      donations straight back to the batcher and collapse the incentive
    ///      to a no-op round-trip.
    function test_OwnDonationsDoNotRefundToBatcher() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        uint256 priorPotA = rewardA.balanceOf(address(batch));
        uint256 priorPotB = rewardB.balanceOf(address(batch));

        // The mock donates into the helper on EVERY mint, in two tokens.
        uint256 donationA = 3e6;
        uint256 donationB = 500;
        rewardA.mint(address(nftMinter), donationA * NUDGE_SIZE);
        rewardB.mint(address(nftMinter), donationB * NUDGE_SIZE);
        nftMinter.setPerMintDonations(_arr(address(rewardA), address(rewardB)), _mins(donationA, donationB));

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(
            rewardA.balanceOf(recipient),
            priorPotA,
            unicode"§4.2 VIOLATED: payout must equal the PRE-LOOP balance exactly; the batcher was refunded its own mid-loop donations, which means the snapshot was taken after the mint loop"
        );
        assertEq(
            rewardB.balanceOf(recipient),
            priorPotB,
            unicode"§4.2 VIOLATED: payout must equal the PRE-LOOP balance exactly; the batcher was refunded its own mid-loop donations, which means the snapshot was taken after the mint loop"
        );
        assertEq(
            rewardA.balanceOf(address(batch)),
            donationA * NUDGE_SIZE,
            unicode"§4.2 VIOLATED: this batch's own donations must REMAIN in the contract to seed the next claimant"
        );
        assertEq(
            rewardB.balanceOf(address(batch)),
            donationB * NUDGE_SIZE,
            unicode"§4.2 VIOLATED: this batch's own donations must REMAIN in the contract to seed the next claimant"
        );
    }

    /// @dev 6. The other side of the same coin, across two sequential batches:
    ///      the SECOND batcher's payout is exactly the FIRST batcher's mid-loop
    ///      donations.
    function test_SecondBatcherReceivesFirstBatchersDonations() public {
        _whitelist(address(rewardA));
        uint256 donationA = 3e6;
        rewardA.mint(address(nftMinter), donationA * NUDGE_SIZE * 2);
        nftMinter.setPerMintDonation(address(rewardA), donationA);

        // Batch 1: contract starts empty, so this batcher earns nothing.
        uint256 cost1 = _costNow(NUDGE_SIZE);
        _fund(caller, cost1);
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost1, _mins(0));
        assertEq(rewardA.balanceOf(recipient), 0, "first batcher into an empty pot earns nothing");
        assertEq(rewardA.balanceOf(address(batch)), donationA * NUDGE_SIZE, "batch 1 donations accumulate");

        // Batch 2: paid exactly what batch 1 left behind.
        address recipient2 = makeAddr("recipient2");
        uint256 cost2 = _costNow(NUDGE_SIZE);
        _fund(caller2, cost2);
        vm.prank(caller2);
        batch.batchMint(NUDGE_SIZE, recipient2, cost2, _mins(0));

        assertEq(
            rewardA.balanceOf(recipient2),
            donationA * NUDGE_SIZE,
            "second batcher receives exactly the first batcher's donations"
        );
        assertEq(rewardA.balanceOf(address(batch)), donationA * NUDGE_SIZE, "batch 2's own donations stay for batch 3");
    }

    // ================================================================ //
    // §4.3 — reentrancy
    // ================================================================ //

    /// @dev 7. A whitelisted "reward token" that reenters `batchMint` from
    ///      its `transfer` hook must be stopped by `nonReentrant`. Under the
    ///      whitelist model the token address is owner-vetted rather than
    ///      attacker-chosen, but the guard is retained as defence in depth —
    ///      an owner mistake must fail closed, not interleave.
    function test_RevertWhen_RewardTokenReentersBatchMint() public {
        MockReentrantERC20 evil = new MockReentrantERC20("Evil", "EVL");
        _whitelist(address(evil));
        evil.mint(address(batch), 1_000 ether);

        uint256 cost = _costNow(NUDGE_SIZE);
        // Fund generously: the nested frame would also try to pull payment.
        _fund(caller, cost * 4);

        evil.arm(address(batch), NUDGE_SIZE, recipient, cost);

        vm.prank(caller);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0));

        assertEq(evil.balanceOf(recipient), 0, "no reward delivered on the reentrant path");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "batch rolled back atomically");
    }

    // ================================================================ //
    // Multi-token payout
    // ================================================================ //

    /// @dev 8. Every whitelisted balance is delivered in full.
    function test_PaysAllWhitelistedTokens() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), POT_A, "full rewardA pot delivered");
        assertEq(rewardB.balanceOf(recipient), POT_B, "full rewardB pot delivered");
        assertEq(rewardA.balanceOf(address(batch)), 0, "rewardA drained");
        assertEq(rewardB.balanceOf(address(batch)), 0, "rewardB drained");
    }

    /// @dev 9. A token the contract holds but the owner did NOT whitelist is
    ///      untouched — the whitelist declares the payout set, nothing else.
    ///      Non-whitelisted balances are `rescueERC20` territory.
    function test_PaysOnlyWhitelistedTokens() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));

        assertEq(rewardC.balanceOf(recipient), 0, "non-whitelisted token never leaves the contract");
        assertEq(rewardC.balanceOf(address(batch)), POT_C, "non-whitelisted token pot intact");
    }

    /// @dev 10. An empty whitelist means empty `minRewards` and a pure mint
    ///      loop — no reward machinery runs.
    function test_EmptyWhitelistMintsWithoutReward() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost, _noMins());

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "mints still happen");
        assertEq(totalPaid, cost, "totalPaid unaffected");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A untouched");
        assertEq(rewardB.balanceOf(address(batch)), POT_B, "pot B untouched");
        _assertNoNudgePaid();
    }

    /// @dev 11. A whitelisted token the contract holds none of is a silent
    ///      no-op: no transfer, no event, no revert (given `min == 0`).
    function test_ZeroBalanceTokenIsNoOp() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");
        _whitelist(address(emptyToken));
        rewardA.mint(address(batch), POT_A);

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0));

        assertEq(emptyToken.balanceOf(recipient), 0, "nothing delivered for an empty pot");
        _assertNoNudgePaid();
    }

    /// @dev 12. `NudgePaid` fires once per token ACTUALLY transferred — so the
    ///      zero-balance entry in the middle produces no event.
    function test_EmitsNudgePaidPerToken() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");
        _whitelist(address(rewardA));
        _whitelist(address(emptyToken));
        _whitelist(address(rewardB));
        _fundPots();

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0, 0));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("NudgePaid(address,address,uint256)");
        address[] memory seenTokens = new address[](logs.length);
        uint256[] memory seenAmounts = new uint256[](logs.length);
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(batch) || logs[i].topics[0] != sig) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), recipient, "NudgePaid recipient");
            seenTokens[seen] = address(uint160(uint256(logs[i].topics[2])));
            seenAmounts[seen] = abi.decode(logs[i].data, (uint256));
            seen++;
        }
        assertEq(seen, 2, "exactly one NudgePaid per token ACTUALLY transferred (empty pot emits nothing)");
        assertEq(seenTokens[0], address(rewardA), "first event names rewardA");
        assertEq(seenAmounts[0], POT_A, "first event carries the full rewardA pot");
        assertEq(seenTokens[1], address(rewardB), "second event names rewardB");
        assertEq(seenAmounts[1], POT_B, "second event carries the full rewardB pot");
    }

    /// @dev 13. Ordering correspondence: `minRewards[i]` binds to
    ///      `getNudgeTokens()[i]` — including AFTER a swap-and-pop removal
    ///      reorders the list. Removing the head moves the tail into its
    ///      slot; a floor breach must then name the token at the NEW index.
    function test_MinRewardsOrderTracksGetNudgeTokens() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _whitelist(address(rewardC));
        _fundPots();

        // Remove the head: swap-and-pop moves rewardC into slot 0.
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(rewardA), false);

        address[] memory listed = batch.getNudgeTokens();
        assertEq(listed.length, 2, "two tokens remain");
        assertEq(listed[0], address(rewardC), "swap-and-pop moved the LAST token into the removed slot");
        assertEq(listed[1], address(rewardB), "unaffected token keeps its slot");

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        // Floors keyed to the OLD order would breach: index 0 is now rewardC
        // (pot POT_C), so a floor of POT_C + 1 at index 0 must revert NAMING
        // rewardC — proving the loop walks the reordered storage array.
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardC), POT_C + 1, POT_C
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(POT_C + 1, 0));

        // Floors keyed to the NEW order succeed and pay per the new order.
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(POT_C, POT_B));

        assertEq(rewardC.balanceOf(recipient), POT_C, "slot 0 (rewardC) paid in full");
        assertEq(rewardB.balanceOf(recipient), POT_B, "slot 1 (rewardB) paid in full");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "removed token's pot untouched");
    }

    // ================================================================ //
    // Floors
    // ================================================================ //

    /// @dev 14. A breached floor anywhere in the whitelist reverts the whole
    ///      batch, naming the offending token, its floor and the actual
    ///      balance.
    function test_RevertWhen_AnyMinRewardExceedsBalance() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _whitelist(address(rewardC));
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);

        // First element breached.
        _fund(caller, cost);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardA), POT_A + 1, POT_A
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(POT_A + 1, 0, 0));

        // Middle element breached.
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardB), POT_B + 1, POT_B
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, POT_B + 1, 0));

        // Last element breached.
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardC), POT_C + 1, POT_C
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0, POT_C + 1));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "no mints survived any floor breach");
    }

    /// @dev 15. All-zero floors never revert — including when nothing at all is
    ///      deliverable (empty pots, or a non-qualifying batch).
    function test_ZeroMinRewardsNeverRevert() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");
        _whitelist(address(rewardA));
        _whitelist(address(emptyToken));

        // Qualifying batch, every pot empty.
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0));
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "qualifying zero-floor batch succeeded");

        // Non-qualifying batch, pots funded.
        _fundPots();
        uint256 below = NUDGE_SIZE - 1;
        uint256 cost2 = _costNow(below);
        _fund(caller, cost2);
        vm.prank(caller);
        batch.batchMint(below, recipient, cost2, _mins(0, 0));
        assertEq(
            nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE + below, "non-qualifying zero-floor batch succeeded"
        );
    }

    /// @dev 16. §3 step 4 runs BEFORE step 5's `safeTransferFrom`. Proven by
    ///      giving the caller funds but NO allowance: if the floor check ran
    ///      after the pull, the revert would be an allowance failure. It is the
    ///      floor error, so the check is genuinely pre-pull.
    function test_FloorCheckedBeforePaymentPull() public {
        _whitelist(address(rewardA));
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        payToken.mint(caller, cost); // funded but deliberately NOT approved
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(rewardA), POT_A + 1, POT_A
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(POT_A + 1));

        assertEq(payToken.balanceOf(caller), callerBefore, "caller's payment token untouched on a floor revert");
        assertEq(payToken.balanceOf(address(batch)), 0, "nothing was pulled into the contract");
    }

    /// @dev 17. `minRewards.length` must equal the FULL whitelist length —
    ///      too short, too long, and non-empty-against-empty all revert with
    ///      `(whitelistLength, minsLength)`.
    function test_RevertWhen_ArrayLengthMismatch() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterMultiToken.BatchMint__ArrayLengthMismatch.selector, 2, 1));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterMultiToken.BatchMint__ArrayLengthMismatch.selector, 2, 3));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0, 0, 0));

        // Empty whitelist demands empty minRewards.
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(rewardA), false);
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(rewardB), false);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterMultiToken.BatchMint__ArrayLengthMismatch.selector, 0, 1));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(0));
    }

    // ================================================================ //
    // Eligibility (owner-controlled)
    // ================================================================ //

    /// @dev 18. Whitelist populated but `count < nudgeSize` — nothing is paid
    ///      and the call still succeeds.
    function test_NoRewardWhenCountBelowNudgeSize() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        uint256 below = NUDGE_SIZE - 1;
        uint256 cost = _costNow(below);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(below, recipient, cost, _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), 0, "no reward below the threshold");
        assertEq(rewardB.balanceOf(recipient), 0, "no reward below the threshold");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A intact");
        _assertNoNudgePaid();
    }

    /// @dev 19. `nudgeSize == 0` disables the incentive entirely.
    function test_NoRewardWhenNudgeSizeZero() public {
        _whitelist(address(rewardA));
        _whitelist(address(rewardB));
        _fundPots();
        vm.prank(owner);
        batch.setNudgeSize(0);

        uint256 count = 25;
        uint256 cost = _costNow(count);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(count, recipient, cost, _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), 0, "no reward when nudgeSize is zero");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A intact when nudgeSize is zero");
        _assertNoNudgePaid();
    }

    // ================================================================ //
    // Documented-behaviour witnesses (§4.4 / §4.5)
    // ================================================================ //

    /// @dev 20. §4.4 witness. `minRewards[i]` is a floor on the CONTRACT'S
    ///      PRE-TRANSFER BALANCE, not on what `recipient` receives. A
    ///      fee-on-transfer token therefore clears the floor and still delivers
    ///      below it — documented, deliberately not defended. If this test ever
    ///      starts failing, someone added balance-delta measurement and §4.4
    ///      must be rewritten before the change lands.
    function test_FeeOnTransferDeliversBelowMinReward() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", 500); // 5%
        _whitelist(address(taxed));
        uint256 pot = 1_000 ether;
        taxed.mint(address(batch), pot);

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        // Floor set to the FULL pot — the snapshot equals it, so no revert.
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _mins(pot));

        uint256 delivered = taxed.balanceOf(recipient);
        assertEq(delivered, pot - (pot * 500) / 10_000, "recipient receives the post-fee amount");
        assertLt(delivered, pot, unicode"§4.4: delivered amount is BELOW the declared floor and that is by design");
        assertEq(taxed.balanceOf(address(batch)), 0, "contract's whole snapshot left the contract");
    }

    /// @dev 21. §4.5 witness (story-025 replacement for the old
    ///      fail-closed-duplicate test). With a set-backed whitelist,
    ///      duplicate reward entries are STRUCTURALLY IMPOSSIBLE: the only
    ///      way to introduce one is `setNudgeTokenWhitelist`, which reverts
    ///      on a re-add. Audit-21 M-02 is resolved by construction.
    function test_DuplicateNudgeTokensStructurallyImpossible() public {
        _whitelist(address(rewardA));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__NudgeTokenAlreadyWhitelisted.selector, address(rewardA)
            )
        );
        batch.setNudgeTokenWhitelist(address(rewardA), true);

        address[] memory listed = batch.getNudgeTokens();
        assertEq(listed.length, 1, "the set never holds a duplicate");
        assertEq(listed[0], address(rewardA), "single entry preserved");
    }

    // ================================================================ //
    // Fuzz
    // ================================================================ //

    /// @dev 22. The §4.6 sweep / `totalPaid` invariant holds for arbitrary
    ///      `count`, `paymentAmount` surplus and whitelist shape:
    ///        - surplus >= DUST_THRESHOLD  -> refunded, `totalPaid == cost`
    ///        - surplus <  DUST_THRESHOLD  -> retained, `totalPaid == paymentAmount`
    ///      and the reward payout never perturbs either side of that ledger.
    function testFuzz_TotalPaidAccounting(uint256 count, uint256 surplus, uint8 shape) public {
        count = bound(count, 1, 8);
        surplus = bound(surplus, 0, 10 ether);
        uint256 numTokens = bound(uint256(shape), 0, 3);

        uint256[] memory minRewards = new uint256[](numTokens);
        MockERC20[3] memory pool = [rewardA, rewardB, rewardC];
        uint256[3] memory pots = [POT_A, POT_B, POT_C];
        for (uint256 i = 0; i < numTokens; i++) {
            pool[i].mint(address(batch), pots[i]);
            _whitelist(address(pool[i]));
        }

        uint256 cost = _costNow(count);
        uint256 paymentAmount = cost + surplus;
        _fund(caller, paymentAmount);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(count, recipient, paymentAmount, minRewards);

        bool qualifies = count >= NUDGE_SIZE;
        if (surplus >= DUST_THRESHOLD) {
            assertEq(totalPaid, cost, "supra-threshold surplus is refunded, totalPaid is the dispatcher cost");
            assertEq(payToken.balanceOf(caller), callerBefore - cost, "caller refunded the surplus");
            assertEq(payToken.balanceOf(address(batch)), 0, "contract swept clean");
        } else {
            assertEq(totalPaid, paymentAmount, "sub-threshold surplus is retained, totalPaid is paymentAmount");
            assertEq(payToken.balanceOf(caller), callerBefore - paymentAmount, "no refund issued");
            assertEq(payToken.balanceOf(address(batch)), surplus, "sub-threshold residue retained");
        }

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), count, "count units minted");
        for (uint256 i = 0; i < numTokens; i++) {
            assertEq(pool[i].balanceOf(recipient), qualifies ? pots[i] : 0, "reward delivered iff the batch qualifies");
        }
    }

    // ---------------------------------------------------------------- //

    /// @dev Assert no `NudgePaid` was emitted since the last `vm.recordLogs()`.
    function _assertNoNudgePaid() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("NudgePaid(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != sig, "no NudgePaid event expected");
        }
    }
}
