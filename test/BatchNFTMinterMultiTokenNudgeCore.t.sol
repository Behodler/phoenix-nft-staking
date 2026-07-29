// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockNoopMinter} from "./mocks/MockNoopMinter.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title BatchNFTMinterMultiToken — nudge-incentive tests
///
/// Exercises the owner-administered `nudgeSize` eligibility gate combined
/// with the OWNER-WHITELISTED nudge-token payout (story-025): whitelist
/// admin (`setNudgeTokenWhitelist`) access control, events and swap-and-pop
/// ordering; setter access control + events; threshold semantics (`>=`);
/// feature-disabled paths (size-zero, empty whitelist, balance-zero); atomic
/// rollback on inner mint revert; the payment token being whitelistable like
/// any other token (story-032 removed the admin-time
/// `token == paymentToken` guard); and the ordering vs. the dust refund sweep.
contract BatchNFTMinterMultiTokenNudgeCoreTest is Test {
    BatchNFTMinterMultiToken internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;
    MockERC20 internal payToken;
    MockERC20 internal nudgeToken;

    address internal owner = makeAddr("batchOwner");
    address internal attacker = makeAddr("attacker");
    address internal caller = address(0xCAFE);
    address internal recipient = address(0xBEEF);
    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250; // 2.5% per mint

    uint256 internal constant NUDGE_SIZE = 5;
    uint256 internal constant NUDGE_FUNDED_AMOUNT = 50_000 ether;

    address internal pauser = makeAddr("batchPauser");

    event NudgeSizeChanged(uint256 newSize);
    event NudgeTokenWhitelistChanged(address indexed token, bool allowed);
    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event TokenMinterSet(address indexed newMinter);
    event DispatcherIndexSet(uint256 indexed dispatcherIndex);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    function setUp() public {
        batch = new BatchNFTMinterMultiToken(owner);
        nftMinter = new MockITokenMinterV2();
        nft = new MockERC1155();
        payToken = new MockERC20("PayToken", "PAY");
        nudgeToken = new MockERC20("NudgeToken", "NDG");

        dispatcher = new MockTokenDispatcherV2(address(payToken));

        nftMinter.setStakedToken(nft);
        nftMinter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        // Wire configs(index).dispatcher -> dispatcher.primeToken() == payToken
        // so the derived payment token equals the funded token.
        nftMinter.setDispatcher(DISPATCHER_INDEX, address(dispatcher));

        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        vm.prank(owner);
        batch.setDispatcherIndex(DISPATCHER_INDEX);
    }

    // ---- helpers ----

    function _expectedTotal(uint256 startPrice, uint256 growthBps, uint256 count)
        internal
        pure
        returns (uint256 total)
    {
        uint256 price = startPrice;
        for (uint256 i = 0; i < count; i++) {
            total += price;
            price = price * (10_000 + growthBps) / 10_000;
        }
    }

    function _fundCaller(uint256 amount, address spender) internal {
        payToken.mint(caller, amount);
        vm.prank(caller);
        payToken.approve(spender, amount);
    }

    /// @dev Set the eligibility threshold, whitelist `nudgeToken` as the
    ///      reward asset (story-025: the reward SET is owner-managed via
    ///      `setNudgeTokenWhitelist`; callers pass only `minRewards`), and
    ///      seed the helper with `NUDGE_FUNDED_AMOUNT` of `nudgeToken`.
    function _enableNudgeFeature(uint256 size) internal {
        vm.prank(owner);
        batch.setNudgeSize(size);
        _whitelist(address(nudgeToken));
        nudgeToken.mint(address(batch), NUDGE_FUNDED_AMOUNT);
    }

    /// @dev Owner-whitelist a nudge token.
    function _whitelist(address token) internal {
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(token, true);
    }

    /// @dev Single-element `minRewards` array.
    function _mins1(uint256 minReward) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = minReward;
    }

    /// @dev "No reward wanted" — the empty-whitelist path.
    function _noMins() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // ----------------------------------------------------------------
    // Setter access control + events
    // ----------------------------------------------------------------

    function test_setNudgeSize_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setNudgeSize(NUDGE_SIZE);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgeSizeChanged(NUDGE_SIZE);
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
        assertEq(batch.nudgeSize(), NUDGE_SIZE, "nudgeSize stored");
    }

    function test_setNudgeSize_acceptsZero() public {
        // Set up a funded feature, then disable via size=0.
        _enableNudgeFeature(NUDGE_SIZE);
        vm.prank(owner);
        batch.setNudgeSize(0);
        assertEq(batch.nudgeSize(), 0, "size zeroed");

        uint256 N = NUDGE_SIZE + 1; // would qualify if feature were enabled
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));
        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no nudge paid when size is zero");
    }

    // ----------------------------------------------------------------
    // Threshold semantics
    // ----------------------------------------------------------------

    function test_batchMint_paysNudgeWhenCountEqualsThreshold() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);
        uint256 callerBefore = nudgeToken.balanceOf(caller);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(
            nudgeToken.balanceOf(recipient),
            recipientBefore + NUDGE_FUNDED_AMOUNT,
            "recipient receives full nudge balance"
        );
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper drained of nudge token");
        assertEq(nudgeToken.balanceOf(caller), callerBefore, "msg.sender does not receive nudge tokens");
    }

    function test_batchMint_paysNudgeWhenCountAboveThreshold() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE + 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(
            nudgeToken.balanceOf(recipient),
            recipientBefore + NUDGE_FUNDED_AMOUNT,
            "recipient receives full nudge balance above threshold"
        );
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper drained");
    }

    function test_batchMint_doesNotPayBelowThreshold() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE - 1;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        // No NudgePaid event expected — recordLogs and verify selector
        // not present.
        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nudgePaidSig = keccak256("NudgePaid(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != nudgePaidSig, "no NudgePaid event below threshold");
        }

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "recipient unchanged below threshold");
        assertEq(nudgeToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "helper retains nudge balance");
    }

    function test_batchMint_doesNotPayWhenSizeIsZero() public {
        // Pot funded and whitelisted, but size remains 0 (default).
        _whitelist(address(nudgeToken));
        nudgeToken.mint(address(batch), NUDGE_FUNDED_AMOUNT);

        uint256 N = 25; // large
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no payout when size is zero");
        assertEq(nudgeToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "helper retains nudge balance");
    }

    /// @dev Reframed for story-025: "no reward configured" is now an EMPTY
    ///      WHITELIST. With no whitelisted tokens the only legal `minRewards`
    ///      is the empty array, and the batch is a plain mint loop even when
    ///      it would otherwise qualify.
    function test_batchMint_doesNotPayWhenEmptyWhitelist() public {
        // Size set (so the batch qualifies), but nothing is whitelisted.
        vm.prank(owner);
        batch.setNudgeSize(1);

        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        // Should succeed without paying any nudge — no revert.
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _noMins());

        // Sanity: nudgeToken not configured, helper should hold none.
        assertEq(nudgeToken.balanceOf(recipient), 0, "recipient gets no nudge");
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper holds no nudge");
    }

    function test_batchMint_doesNotPayWhenBalanceIsZero() public {
        // Threshold set and the token whitelisted, but no balance funded.
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
        _whitelist(address(nudgeToken));

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nudgePaidSig = keccak256("NudgePaid(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != nudgePaidSig, "no NudgePaid event when balance is zero");
        }

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "recipient unchanged when balance is zero");
    }

    // ----------------------------------------------------------------
    // Atomicity vs. inner mint revert
    // ----------------------------------------------------------------

    function test_batchMint_nudgeIsAtomicWithRevert() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        // Force the 3rd inner mint to revert.
        nftMinter.setRevertAtCall(3, true);

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);
        uint256 batchBefore = nudgeToken.balanceOf(address(batch));

        vm.prank(caller);
        vm.expectRevert(MockITokenMinterV2.MockITokenMinterV2__ForcedRevert.selector);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "recipient nudge unchanged on revert");
        assertEq(nudgeToken.balanceOf(address(batch)), batchBefore, "helper nudge balance unchanged on revert");
    }

    // ----------------------------------------------------------------
    // Payment token as a nudge token (no admin-time guard since story 032)
    // ----------------------------------------------------------------

    /// @dev Story-025 moved a token-distinctness exclusion from the per-call
    ///      snapshot loop to WHITELIST-ADMIN TIME; story-029 removed the
    ///      runtime half and demoted the admin half to defence in depth;
    ///      story-032 removed the admin half too. The derived payment token is
    ///      now whitelistable like any other ERC20, in one call. What keeps the
    ///      payment-token pot out of the caller's hands is the budget-sourced
    ///      refund, not this call refusing to happen (§4.1).
    function test_whitelist_acceptsPaymentToken() public {
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgeTokenWhitelistChanged(address(payToken), true);
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(payToken), true);

        address[] memory tokens = batch.getNudgeTokens();
        assertEq(tokens.length, 1, "payment token lands on the whitelist");
        assertEq(tokens[0], address(payToken), "and it is the entry that landed");
        assertTrue(batch.isNudgeToken(address(payToken)), "isNudgeToken agrees");
    }

    /// @dev With an empty whitelist the snapshot loop has zero iterations, so
    ///      there is nothing to snapshot, floor-check or pay — the call goes
    ///      through as a plain mint loop. (Story-025 framed this as "no
    ///      exclusion logic can fire"; since story-032 there is no exclusion
    ///      left to fire in the first place, and the test is simply the
    ///      zero-length-whitelist path.)
    function test_batchMint_emptyWhitelistIsAPlainMintLoop() public {
        uint256 N = 2;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _noMins());

        // Reaching this point without revert is the assertion.
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "mint succeeded with feature off");
    }

    // ----------------------------------------------------------------
    // Budget refund and nudge payout coexist
    //
    // Story-029 SWAPPED these two steps: the caller's unspent budget is
    // refunded at step 9 and the nudge is paid at step 10, so a payout can
    // never be funded out of a refund that is owed, and vice versa. The
    // assertions below are order-agnostic on purpose — they pin that both
    // transfers happen, in the right assets, to the right parties.
    // ----------------------------------------------------------------

    function test_batchMint_refundsBudgetAndPaysNudge() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 surplus = 7 ether;
        uint256 paid = expected + surplus;
        _fundCaller(paid, address(batch));

        uint256 callerPayBefore = payToken.balanceOf(caller);
        uint256 recipientNudgeBefore = nudgeToken.balanceOf(recipient);

        // Both transfers must happen. The step order (refund at 9, payout at 10)
        // is covered by the inline NatSpec's ORDER IS LOAD-BEARING note; here we
        // assert only that the nudge event fires and both assets land correctly.
        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, _mins1(0));

        // Nudge: recipient got funded amount in nudgeToken.
        assertEq(
            nudgeToken.balanceOf(recipient), recipientNudgeBefore + NUDGE_FUNDED_AMOUNT, "recipient receives nudge"
        );
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper drained of nudge");

        // Refund: msg.sender receives the surplus of payToken (not the nudge token).
        assertEq(payToken.balanceOf(caller), callerPayBefore - expected, "surplus refunded in payToken");
        assertEq(totalPaid, expected, "totalPaid is dispatcher cost, not paymentAmount");
        assertEq(nudgeToken.balanceOf(caller), 0, "msg.sender does not receive nudge tokens");
    }

    // ----------------------------------------------------------------
    // Self-refund regression (donation-order-fix): the nudge pot is
    // snapshotted BEFORE the mint loop, so a qualifying batcher's own
    // per-mint donations stay in the contract for the NEXT claimant rather
    // than refunding straight back to them in the same transaction.
    // ----------------------------------------------------------------

    /// @dev The dispatcher donates `d` of the nudge token into this helper on
    ///      every mint. Pre-fix, the pot was read AFTER the loop, so a
    ///      qualifying batcher scooped the prior pot `P` PLUS its own
    ///      `count * d` donations, leaving 0 for the next minter. After the
    ///      snapshot-before-loop fix the batcher receives EXACTLY the prior
    ///      pot `P`, and the `count * d` it donated mid-loop stays in the
    ///      contract to seed the next claimant.
    function test_batchMint_selfRefund_donationDuringLoopStaysForNextMinter() public {
        // Prior accumulated pot `P` from earlier minters.
        _enableNudgeFeature(NUDGE_SIZE);
        uint256 P = nudgeToken.balanceOf(address(batch));
        assertEq(P, NUDGE_FUNDED_AMOUNT, "prior pot funded");

        uint256 N = NUDGE_SIZE; // clears the gate
        uint256 d = 3 ether; // donation pushed into the helper per mint
        uint256 loopDonations = N * d;

        // The mock donates `d` of nudgeToken into the helper on every mint;
        // pre-fund the mock with `count * d` so it can.
        nudgeToken.mint(address(nftMinter), loopDonations);
        nftMinter.setPerMintDonation(address(nudgeToken), d);

        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);
        uint256 callerBefore = nudgeToken.balanceOf(caller);

        // The batcher is paid EXACTLY the prior pot `P`, not `P + count*d`.
        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), P);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(
            nudgeToken.balanceOf(recipient),
            recipientBefore + P,
            "recipient receives only the PRIOR pot, not its own loop donations"
        );
        assertEq(
            nudgeToken.balanceOf(address(batch)),
            loopDonations,
            "this batch's loop donations stay in the contract for the next minter"
        );
        assertEq(nudgeToken.balanceOf(caller), callerBefore, "msg.sender receives no nudge tokens");
    }

    // ----------------------------------------------------------------
    // Minter pinning — drain regression + access control
    //
    // Pre-fix, `batchMint` took the NFT minter as a caller-supplied
    // parameter. An attacker passed a no-op minter, faked `count >=
    // nudgeSize` cheap "mints", cleared the gate, and walked off with the
    // contract's entire nudge balance for ~no cost (real mainnet incident:
    // 54 faked mints drained 61.297674 USDC). With the minter pinned to
    // owner-set state the parameter is gone, so the only minter a batch can
    // use is the trusted one that actually charges for each mint. These
    // tests assert the attacker path now reverts and no funds move.
    // ----------------------------------------------------------------

    /// @dev The exact pre-fix exploit, now closed: attacker funds nothing,
    ///      passes a no-op minter (impossible — the param is gone), and tries
    ///      to clear the nudge gate. With the real minter pinned, the no-op
    ///      attacker minter cannot be selected; the real minter pulls payment
    ///      the attacker never provided, so the batch reverts and the pot is
    ///      untouched.
    function test_batchMint_drainRegression_attackerMinterCannotDrainPot() public {
        _enableNudgeFeature(NUDGE_SIZE);
        uint256 potBefore = nudgeToken.balanceOf(address(batch));
        assertGt(potBefore, 0, "pot funded");

        // Attacker pre-fix would have passed this no-op minter; it now has no
        // way into batchMint. Sanity that it exists and is a real ITokenMinterV2.
        MockNoopMinter noop = new MockNoopMinter();
        assertTrue(address(noop) != address(nftMinter), "noop distinct from pinned minter");

        // Attacker fakes a qualifying batch but funds nothing. The pinned
        // real minter tries to pull `START_PRICE` of payToken from the helper,
        // which the helper does not hold -> revert, pot untouched.
        uint256 N = NUDGE_SIZE; // clears the gate
        vm.prank(attacker);
        vm.expectRevert();
        batch.batchMint(N, attacker, 0, _mins1(0));

        assertEq(nudgeToken.balanceOf(address(batch)), potBefore, "pot untouched after failed drain");
        assertEq(nudgeToken.balanceOf(attacker), 0, "attacker received nothing");
    }

    /// @dev Happy path: a genuine caller pays for `>= nudgeSize` real mints at
    ///      the dispatcher's ramping price, qualifies, and the nudge pays out.
    function test_batchMint_pinnedMinter_happyPathPaysNudge() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "recipient gets N real NFT units");
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore + NUDGE_FUNDED_AMOUNT, "nudge paid on genuine batch");
    }

    // ----------------------------------------------------------------
    // setDispatcherIndex — access control, event, callable while paused
    // ----------------------------------------------------------------

    function test_setDispatcherIndex_onlyOwner_andEmits() public {
        uint256 newIndex = 4;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setDispatcherIndex(newIndex);

        vm.expectEmit(true, true, true, true, address(batch));
        emit DispatcherIndexSet(newIndex);
        vm.prank(owner);
        batch.setDispatcherIndex(newIndex);
        assertEq(batch.dispatcherIndex(), newIndex, "dispatcherIndex stored");
    }

    function test_setDispatcherIndex_worksWhilePaused() public {
        vm.prank(owner);
        batch.setPauser(pauser);
        vm.prank(pauser);
        batch.pause();

        uint256 newIndex = 4;
        vm.expectEmit(true, true, true, true, address(batch));
        emit DispatcherIndexSet(newIndex);
        vm.prank(owner);
        batch.setDispatcherIndex(newIndex);
        assertEq(batch.dispatcherIndex(), newIndex, "dispatcherIndex set while paused");
    }

    function test_setTokenMinter_onlyOwner_andEmits() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));

        vm.expectEmit(true, true, true, true, address(batch));
        emit TokenMinterSet(address(nftMinter));
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        assertEq(address(batch.tokenMinter()), address(nftMinter), "tokenMinter stored");
    }

    function test_batchMint_revertsWhenMinterNotConfigured() public {
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));

        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 1);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__MinterNotConfigured.selector);
        batch.batchMint(1, recipient, expected, _noMins());
    }

    // ----------------------------------------------------------------
    // Derived payment token + dispatcher pinning (incident §4, reframed)
    //
    // Story-013 closed the "mismatched payment token" drain by relying on a
    // wrong CALLER-SUPPLIED token reverting the inner mint. Story-014 removes
    // the caller's token entirely: `paymentToken` is DERIVED from the pinned
    // dispatcher's `primeToken()`, so a wrong/zero payment asset can no longer
    // be expressed via the public API. The old "mismatched payment token"
    // test is therefore reframed below into:
    //   (a) a DispatcherNotConfigured test (index 0 AND zero-dispatcher), and
    //   (b) a derived-token assertion that the funded prime token is what
    //       moves, proving a wrong/zero payment asset cannot drain the pot.
    // The nudge-token == prime-token admin check that story-025 added is GONE
    // (story-032). Story-029 had already reduced it to defence in depth, because
    // the old "dust-sweep vector" it guarded against is closed at the root: the
    // refund is sourced from the caller's tracked budget rather than from
    // `balanceOf`. Note that `batchMint`'s own configuration guards below are
    // entirely unrelated to it and are untouched.
    // ----------------------------------------------------------------

    /// @dev `batchMint` reverts `BatchMint__DispatcherNotConfigured` when the
    ///      dispatcher is unset — both when `dispatcherIndex == 0` and when the
    ///      pinned index resolves to a zero dispatcher. No funds move. This
    ///      replaces 013's caller-supplied wrong-token path: a wrong/zero
    ///      payment asset can no longer be selected, so an unconfigured
    ///      dispatcher (rather than a mismatched token) is the new "no drain"
    ///      gate.
    function test_batchMint_revertsWhenDispatcherIndexUnset() public {
        _enableNudgeFeature(NUDGE_SIZE);
        uint256 potBefore = nudgeToken.balanceOf(address(batch));

        // Unpin the dispatcher index (0 = unconfigured).
        vm.prank(owner);
        batch.setDispatcherIndex(0);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(nudgeToken.balanceOf(address(batch)), potBefore, "pot untouched when dispatcher unset");
        assertEq(nudgeToken.balanceOf(recipient), 0, "recipient gets no nudge when dispatcher unset");
    }

    /// @dev A pinned index whose `configs(index).dispatcher == address(0)`
    ///      also reverts `BatchMint__DispatcherNotConfigured` — there is no
    ///      dispatcher to derive a prime token from, so no funds move.
    function test_batchMint_revertsWhenResolvedDispatcherIsZero() public {
        _enableNudgeFeature(NUDGE_SIZE);
        uint256 potBefore = nudgeToken.balanceOf(address(batch));

        // Pin an index that has price/growth configured but a zero dispatcher.
        uint256 zeroDispatcherIndex = 9;
        nftMinter.setConfig(zeroDispatcherIndex, START_PRICE, GROWTH_BPS);
        // (no setDispatcher -> resolves to address(0))
        vm.prank(owner);
        batch.setDispatcherIndex(zeroDispatcherIndex);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(N, recipient, expected, _mins1(0));

        assertEq(nudgeToken.balanceOf(address(batch)), potBefore, "pot untouched when dispatcher resolves to zero");
    }

    /// @dev Derived-token coverage (reframes 013's "wrong payment asset cannot
    ///      drain"): the helper pulls/approves/sweeps the token DERIVED from
    ///      the dispatcher's `primeToken()` — the funded `payToken` — and the
    ///      caller passes no token at all. Asserts the funded prime token is
    ///      exactly what moves, so no other (wrong/zero) asset could ever be
    ///      used to drain the pot.
    function test_batchMint_usesDerivedPrimeTokenForPayment() public {
        // Sanity: the dispatcher's prime token is the funded payToken.
        (address d,,,) = nftMinter.configs(DISPATCHER_INDEX);
        assertEq(d, address(dispatcher), "configs dispatcher wired");
        assertEq(MockTokenDispatcherV2(d).primeToken(), address(payToken), "derived prime token == payToken");

        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 surplus = 7 ether;
        uint256 paid = expected + surplus;
        _fundCaller(paid, address(batch));

        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, _noMins());

        // The DERIVED payToken is what was pulled and swept — surplus refunded.
        assertEq(payToken.balanceOf(caller), callerBefore - expected, "derived token pulled; surplus refunded");
        assertEq(payToken.balanceOf(address(batch)), 0, "no derived-token balance left in helper");
        assertEq(totalPaid, expected, "totalPaid is dispatcher cost in the derived token");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "recipient minted via pinned dispatcher");
    }

    /// @dev Dust-sweep vector (incident §4), rewritten for story-032.
    ///
    ///      Earlier revisions of this test asserted that "the only path by which
    ///      the derived prime token could become a nudge payout — an owner
    ///      whitelisting it — reverts at admin time", and concluded that
    ///      "neither a caller nor a
    ///      misconfiguring owner can turn the payment-token balance into a
    ///      claimable pot". **That conclusion was already false when it was
    ///      written**: the owner could repoint `tokenMinter`/`dispatcherIndex`
    ///      and reach exactly that state under an existing whitelist entry. It
    ///      is false twice over now that story-032 has deleted the admin-time
    ///      revert.
    ///
    ///      The genuine invariant — the one that actually closed the incident,
    ///      in story-029 — is about the refund's SOURCE, not the whitelist's
    ///      shape: the payment-token pot, whitelisted or not, can never leave
    ///      through the refund, because the refund is bounded by the caller's
    ///      locally-tracked `budget`. So with the pot whitelisted, a qualifying
    ///      batch delivers it to `recipient` as a nudge, and `msg.sender`
    ///      receives only their own unspent budget. The `61_297674` figure is
    ///      the real mainnet pot size the incident was reported against and is
    ///      the point of the test.
    function test_whitelist_derivedPrimeTokenPotPaysOutAndIsNeverRefunded() public {
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);

        // Fund the helper with payToken — the historical drain target.
        uint256 pot = 61_297674; // the real mainnet pot size
        payToken.mint(address(batch), pot);

        // Story-032: one call, no repointing, no decoy entry.
        _whitelist(address(payToken));
        assertEq(batch.getNudgeTokens().length, 1, "the derived prime token IS whitelistable");

        uint256 cost = _expectedTotal(START_PRICE, GROWTH_BPS, NUDGE_SIZE);
        uint256 surplus = 7 ether; // >= DUST_THRESHOLD, so it is refunded
        _fundCaller(cost + surplus, address(batch));
        uint256 callerBefore = payToken.balanceOf(caller);
        uint256 recipientBefore = payToken.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(payToken), pot);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost + surplus, _mins1(0));

        assertEq(payToken.balanceOf(recipient), recipientBefore + pot, "the pot is PAID to the claimant as a nudge");
        assertEq(
            payToken.balanceOf(caller),
            callerBefore - cost,
            "REFUND IS BUDGET-BOUNDED: the caller gets back only their own unspent budget, never the pot"
        );
        assertEq(payToken.balanceOf(address(batch)), 0, "pot delivered in full; nothing stranded");
        assertEq(totalPaid, cost, "totalPaid is the cumulative charge, not net of the pot");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "batch stays live under the collision");
    }

    // ----------------------------------------------------------------
    // minReward slippage guard (audit pns13m1 — front-running / nudge griefing)
    //
    // A user who calls `batchMint` expecting the nudge reward can be front-run
    // by an MEV bot that lands its own qualifying batch first and sweeps the
    // full (balance-based, first-qualifier-takes-all) pot. The victim then
    // mints at the dispatcher's price for zero/reduced reward — still paying
    // the full mint cost. `minReward` lets the caller declare the minimum nudge
    // reward they accept; if the deliverable reward is below it, the WHOLE batch
    // reverts, rolling back the mints and the payment pull. `minReward == 0`
    // preserves today's behaviour exactly.
    //
    // NOTE: `minReward` is slippage protection, not MEV elimination — the
    // front-runner still wins the pot. It only stops the loser from minting for
    // less than their stated floor.
    // ----------------------------------------------------------------

    /// @dev Front-run / pot-drained: the pot is swept by an attacker's own
    ///      qualifying batch, then the victim's batch (with `minReward` set to
    ///      the pot they observed) reverts `BatchMint__RewardBelowMinimum`. No
    ///      NFTs are minted to the victim's recipient and no payment is pulled.
    function test_batchMint_minReward_frontRunRevertsAndRollsBack() public {
        _enableNudgeFeature(NUDGE_SIZE);
        uint256 observedPot = nudgeToken.balanceOf(address(batch));
        assertEq(observedPot, NUDGE_FUNDED_AMOUNT, "pot funded for the victim to observe");

        // Attacker front-runs with their own qualifying batch and sweeps the pot.
        uint256 NA = NUDGE_SIZE;
        uint256 attackerCost = _expectedTotal(START_PRICE, GROWTH_BPS, NA);
        payToken.mint(attacker, attackerCost);
        vm.prank(attacker);
        payToken.approve(address(batch), attackerCost);
        vm.prank(attacker);
        batch.batchMint(NA, attacker, attackerCost, _mins1(0));
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "attacker drained the pot");

        // Victim's tx (was pending) lands second. They set minReward to the pot
        // they expected to win. The dispatcher price has ramped from the
        // attacker's mints, so fund a generous buffer — enough that the inner
        // mints would succeed and the slippage floor (not insufficient payment)
        // is what reverts. Reward deliverable is now 0 < minReward -> revert.
        uint256 N = NUDGE_SIZE;
        uint256 buffer = _expectedTotal(START_PRICE, GROWTH_BPS, 4 * N); // ample headroom
        _fundCaller(buffer, address(batch));

        uint256 callerPayBefore = payToken.balanceOf(caller);
        uint256 recipientNftBefore = nft.balanceOf(recipient, DISPATCHER_INDEX);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(nudgeToken), observedPot, 0
            )
        );
        batch.batchMint(N, recipient, buffer, _mins1(observedPot));

        // No mint cost was pulled (atomic rollback) and the victim minted nothing.
        assertEq(payToken.balanceOf(caller), callerPayBefore, "no payment pulled on slippage revert");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), recipientNftBefore, "victim minted no NFTs");
    }

    /// @dev Floor met — happy path: `minReward <= nudgeAmount` succeeds, mints
    ///      `count`, pays the full nudge, and the dust/totalPaid accounting is
    ///      unchanged.
    function test_batchMint_minReward_floorMetHappyPath() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 surplus = 7 ether;
        uint256 paid = expected + surplus;
        _fundCaller(paid, address(batch));

        uint256 callerPayBefore = payToken.balanceOf(caller);
        uint256 recipientNudgeBefore = nudgeToken.balanceOf(recipient);

        // Floor strictly below the pot.
        uint256 floor = NUDGE_FUNDED_AMOUNT - 1 ether;

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, _mins1(floor));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "minted count");
        assertEq(nudgeToken.balanceOf(recipient), recipientNudgeBefore + NUDGE_FUNDED_AMOUNT, "full nudge paid");
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper drained of nudge");
        assertEq(payToken.balanceOf(caller), callerPayBefore - expected, "surplus refunded unchanged");
        assertEq(totalPaid, expected, "totalPaid accounting unchanged");
    }

    /// @dev Floor exactly equal: `minReward == nudgeAmount` succeeds (boundary —
    ///      the guard is `<`, not `<=`).
    function test_batchMint_minReward_floorExactlyEqualSucceeds() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientNudgeBefore = nudgeToken.balanceOf(recipient);

        // Floor exactly equal to the pot.
        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(NUDGE_FUNDED_AMOUNT));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "minted count at exact floor");
        assertEq(
            nudgeToken.balanceOf(recipient),
            recipientNudgeBefore + NUDGE_FUNDED_AMOUNT,
            "full nudge paid at exact floor"
        );
    }

    /// @dev `minReward == 0` is backward-compatible: a qualifying batch still
    ///      pays the nudge, and a non-qualifying batch still succeeds without
    ///      paying — exactly as today, no revert added.
    function test_batchMint_minReward_zeroIsBackwardCompatible() public {
        _enableNudgeFeature(NUDGE_SIZE);

        // Qualifying batch, minReward == 0 -> pays full nudge.
        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));
        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore + NUDGE_FUNDED_AMOUNT, "nudge paid with floor 0");

        // Non-qualifying batch, minReward == 0 -> succeeds, no payout, no revert.
        // The price has ramped from the first batch; fund from the current price.
        uint256 NB = NUDGE_SIZE - 1;
        uint256 priceNow = nftMinter.getPrice(DISPATCHER_INDEX);
        uint256 expectedB = _expectedTotal(priceNow, GROWTH_BPS, NB);
        _fundCaller(expectedB, address(batch));
        uint256 recipientBeforeB = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(NB, recipient, expectedB, _mins1(0));
        assertEq(nudgeToken.balanceOf(recipient), recipientBeforeB, "no payout below threshold, no revert with floor 0");
    }

    /// @dev Floor set but nudge not triggered: `count < nudgeSize` with
    ///      `minReward > 0` reverts `BatchMint__RewardBelowMinimum(minReward, 0)`
    ///      and mints nothing — the caller demanded a reward none is available.
    function test_batchMint_minReward_floorSetButNudgeNotTriggeredReverts() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE - 1; // below threshold -> reward deliverable is 0
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 callerPayBefore = payToken.balanceOf(caller);
        uint256 recipientNftBefore = nft.balanceOf(recipient, DISPATCHER_INDEX);

        uint256 floor = 1; // any non-zero floor

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(nudgeToken), floor, 0
            )
        );
        batch.batchMint(N, recipient, expected, _mins1(floor));

        assertEq(payToken.balanceOf(caller), callerPayBefore, "no payment pulled when floor unmet below threshold");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), recipientNftBefore, "minted nothing when floor unmet");
    }

    /// @dev Revert carries the two error fields: `minReward` and `actualReward`.
    ///      Here the pot is partially funded below the floor, so `actualReward`
    ///      is the (non-zero) deliverable balance.
    function test_batchMint_minReward_revertCarriesFields() public {
        // Configure the threshold but fund the pot below the floor we'll request.
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
        _whitelist(address(nudgeToken));
        uint256 actualPot = 123 ether;
        nudgeToken.mint(address(batch), actualPot);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 floor = 200 ether; // > actualPot

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__RewardBelowMinimum.selector, address(nudgeToken), floor, actualPot
            )
        );
        batch.batchMint(N, recipient, expected, _mins1(floor));
    }

    // ----------------------------------------------------------------
    // setNudgeTokenWhitelist — owner-managed nudge-token set (story-025)
    //
    // Hand-rolled enumerable set (address[] + 1-based index mapping,
    // swap-and-pop removal — the InPlaceNFTStakerMigrator precedent,
    // because OZ EnumerableSet needs solc ^0.8.24 and this repo pins
    // 0.8.20). Adding derives the payment token exactly as batchMint does
    // and rejects collisions; both no-op directions revert loudly.
    // ----------------------------------------------------------------

    function test_whitelist_addAppendsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgeTokenWhitelistChanged(address(nudgeToken), true);
        _whitelist(address(nudgeToken));

        address[] memory listed = batch.getNudgeTokens();
        assertEq(listed.length, 1, "one token whitelisted");
        assertEq(listed[0], address(nudgeToken), "token stored in order");
    }

    function test_whitelist_removeLastElementEmptiesAndEmits() public {
        _whitelist(address(nudgeToken));

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgeTokenWhitelistChanged(address(nudgeToken), false);
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);

        assertEq(batch.getNudgeTokens().length, 0, "whitelist emptied");
    }

    /// @dev Swap-and-pop: removing a MIDDLE element moves the LAST element
    ///      into its slot. O(1) removal in exchange for reordering — which
    ///      is why `getNudgeTokens()` must be re-fetched before every
    ///      batchMint.
    function test_whitelist_removeMiddle_swapAndPopMovesLastIntoSlot() public {
        MockERC20 tokenB = new MockERC20("TokenB", "TKB");
        MockERC20 tokenC = new MockERC20("TokenC", "TKC");
        _whitelist(address(nudgeToken)); // slot 0
        _whitelist(address(tokenB)); // slot 1 (middle)
        _whitelist(address(tokenC)); // slot 2 (last)

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(tokenB), false);

        address[] memory listed = batch.getNudgeTokens();
        assertEq(listed.length, 2, "one removed");
        assertEq(listed[0], address(nudgeToken), "head untouched");
        assertEq(listed[1], address(tokenC), "LAST element moved into the removed middle slot");
    }

    function test_whitelist_reAddAfterRemoveAppendsAtEnd() public {
        MockERC20 tokenB = new MockERC20("TokenB", "TKB");
        _whitelist(address(nudgeToken));
        _whitelist(address(tokenB));

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);
        // Re-add after removal: appended at the END, not restored to slot 0.
        _whitelist(address(nudgeToken));

        address[] memory listed = batch.getNudgeTokens();
        assertEq(listed.length, 2, "both tokens whitelisted again");
        assertEq(listed[0], address(tokenB), "survivor holds slot 0 after swap-and-pop");
        assertEq(listed[1], address(nudgeToken), "re-added token appended at the end");
    }

    function test_whitelist_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__ZeroNudgeToken.selector);
        batch.setNudgeTokenWhitelist(address(0), true);
    }

    /// @dev Loud revert, not a silent no-op — and the §4.5 duplicate story:
    ///      this revert is what makes duplicate reward entries structurally
    ///      impossible (audit-21 M-02 resolved by construction).
    function test_whitelist_revertsOnAlreadyWhitelisted() public {
        _whitelist(address(nudgeToken));

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__NudgeTokenAlreadyWhitelisted.selector, address(nudgeToken)
            )
        );
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);
    }

    function test_whitelist_revertsOnRemovingAbsentToken() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterMultiToken.BatchMint__NudgeTokenNotWhitelisted.selector, address(nudgeToken)
            )
        );
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);
    }

    /// @dev The add branch used to derive the payment token exactly as
    ///      `batchMint` does, purely so it could compare against it, and so an
    ///      unconfigured minter blocked whitelisting as a side effect of where
    ///      that check sat. Story-032 removed the derivation with the check, so
    ///      adding now works while `tokenMinter` is unset. That was never a
    ///      deliberate invariant — no runbook ordering depends on it — and its
    ///      removal makes add symmetric with remove (below).
    ///
    ///      `batchMint`'s OWN configuration guards are untouched: see
    ///      `test_batchMint_revertsWhenMinterNotConfigured` and the two
    ///      `DispatcherNotConfigured` cases.
    function test_whitelist_addWorksWhenMinterNotConfigured() public {
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);
        assertTrue(batch.isNudgeToken(address(nudgeToken)), "add works with minter unset");
    }

    /// @dev Second unconfigured state: minter present, `dispatcherIndex == 0`.
    function test_whitelist_addWorksWhenDispatcherIndexUnset() public {
        vm.prank(owner);
        batch.setDispatcherIndex(0);

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);
        assertTrue(batch.isNudgeToken(address(nudgeToken)), "add works with dispatcherIndex unset");
    }

    /// @dev Third unconfigured state: a non-zero index that RESOLVES to a zero
    ///      dispatcher. Kept distinct from the two above because it is a
    ///      different failure of `_resolvePaymentPath` — it is reached through
    ///      `configs()` rather than a local zero check — and `batchMint` still
    ///      reverts on it.
    function test_whitelist_addWorksWhenResolvedDispatcherIsZero() public {
        // Pin an index with price config but no dispatcher wired.
        uint256 zeroDispatcherIndex = 9;
        nftMinter.setConfig(zeroDispatcherIndex, START_PRICE, GROWTH_BPS);
        vm.prank(owner);
        batch.setDispatcherIndex(zeroDispatcherIndex);

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);
        assertTrue(batch.isNudgeToken(address(nudgeToken)), "add works with a zero-resolving dispatcher");
    }

    /// @dev Removal performs NO payment-token derivation, so it stays
    ///      possible even after the minter is unconfigured — the owner can
    ///      always shrink the whitelist. Unmodified since story-025; as of
    ///      story-032 the ADD branch is symmetric with it (the three
    ///      `addWorksWhen…` tests above), so neither direction of this setter
    ///      reads the payment path any more.
    function test_whitelist_removeWorksWhenMinterNotConfigured() public {
        _whitelist(address(nudgeToken));
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);
        assertEq(batch.getNudgeTokens().length, 0, "removal works with minter unset");
    }

    function test_whitelist_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);

        _whitelist(address(nudgeToken));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);
    }

    /// @dev Whitelist admin follows the existing setter convention: stays
    ///      callable while paused.
    function test_whitelist_worksWhilePaused() public {
        vm.prank(owner);
        batch.setPauser(pauser);
        vm.prank(pauser);
        batch.pause();

        _whitelist(address(nudgeToken));
        assertEq(batch.getNudgeTokens().length, 1, "whitelisting works while paused");

        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), false);
        assertEq(batch.getNudgeTokens().length, 0, "unwhitelisting works while paused");
    }

    // ----------------------------------------------------------------
    // rescueERC20 (owner escape hatch)
    // ----------------------------------------------------------------

    function test_rescueERC20_ownerRecoversToken() public {
        nudgeToken.mint(address(batch), 1_000 ether);
        address dest = makeAddr("rescueDest");

        vm.expectEmit(true, true, true, true, address(batch));
        emit Rescued(address(nudgeToken), dest, 400 ether);
        vm.prank(owner);
        batch.rescueERC20(IERC20(address(nudgeToken)), dest, 400 ether);

        assertEq(nudgeToken.balanceOf(dest), 400 ether, "dest received rescued amount");
        assertEq(nudgeToken.balanceOf(address(batch)), 600 ether, "remainder stays (explicit amount)");
    }

    function test_rescueERC20_nonOwnerReverts() public {
        nudgeToken.mint(address(batch), 1_000 ether);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.rescueERC20(IERC20(address(nudgeToken)), attacker, 1 ether);
    }

    function test_rescueERC20_zeroRecipientReverts() public {
        nudgeToken.mint(address(batch), 1 ether);
        vm.prank(owner);
        vm.expectRevert(BatchNFTMinterMultiToken.Rescue__ZeroRecipient.selector);
        batch.rescueERC20(IERC20(address(nudgeToken)), address(0), 1 ether);
    }

    function test_rescueERC20_worksWhilePaused() public {
        nudgeToken.mint(address(batch), 1_000 ether);
        vm.prank(owner);
        batch.setPauser(pauser);
        vm.prank(pauser);
        batch.pause();

        address dest = makeAddr("rescueDest");
        vm.prank(owner);
        batch.rescueERC20(IERC20(address(nudgeToken)), dest, 1_000 ether);
        assertEq(nudgeToken.balanceOf(dest), 1_000 ether, "rescue works while paused");
    }

    // ----------------------------------------------------------------
    // Pausable (global pauser integration)
    // ----------------------------------------------------------------

    function test_setPauser_onlyOwner_andEmits() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setPauser(pauser);

        vm.expectEmit(true, true, true, true, address(batch));
        emit PauserChanged(address(0), pauser);
        vm.prank(owner);
        batch.setPauser(pauser);
        assertEq(batch.pauser(), pauser, "pauser stored");
    }

    function test_pauseUnpause_revertForNonPauser() public {
        vm.prank(owner);
        batch.setPauser(pauser);

        vm.prank(attacker);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.pause();

        vm.prank(pauser);
        batch.pause();

        vm.prank(attacker);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.unpause();
    }

    function test_batchMint_revertsWhenPaused_succeedsAfterUnpause() public {
        _enableNudgeFeature(NUDGE_SIZE);
        vm.prank(owner);
        batch.setPauser(pauser);
        vm.prank(pauser);
        batch.pause();

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        batch.batchMint(N, recipient, expected, _mins1(0));

        vm.prank(pauser);
        batch.unpause();
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, _mins1(0));
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "mint resumes after unpause");
    }
}

