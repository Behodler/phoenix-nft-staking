// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ITokenMinterV2} from "yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchNFTMinter} from "../src/BatchNFTMinter.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockNoopMinter} from "./mocks/MockNoopMinter.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title BatchNFTMinter — nudge-incentive tests
///
/// Exercises the owner-administered `nudgeSize` / `nudgePaymentToken`
/// feature: setter access control + events, threshold semantics
/// (`>=`), feature-disabled paths (size-zero, token-unset, balance-zero),
/// atomic rollback on inner mint revert, the up-front
/// `nudgePaymentToken == paymentToken` distinctness guard, and the
/// ordering vs. the dust refund sweep.
contract BatchNFTMinterNudgeTest is Test {
    BatchNFTMinter internal batch;
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
    event NudgePaymentTokenChanged(address indexed newToken);
    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event TokenMinterSet(address indexed newMinter);
    event DispatcherIndexSet(uint256 indexed dispatcherIndex);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    function setUp() public {
        batch = new BatchNFTMinter(owner);
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

    /// @dev Configure both nudge knobs and seed the helper with
    ///      `NUDGE_FUNDED_AMOUNT` of `nudgeToken`.
    function _enableNudgeFeature(uint256 size) internal {
        vm.prank(owner);
        batch.setNudgePaymentToken(address(nudgeToken));
        vm.prank(owner);
        batch.setNudgeSize(size);
        nudgeToken.mint(address(batch), NUDGE_FUNDED_AMOUNT);
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

    function test_setNudgePaymentToken_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        batch.setNudgePaymentToken(address(nudgeToken));

        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaymentTokenChanged(address(nudgeToken));
        vm.prank(owner);
        batch.setNudgePaymentToken(address(nudgeToken));
        assertEq(batch.nudgePaymentToken(), address(nudgeToken), "nudgePaymentToken stored");
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
        batch.batchMint(N, recipient, expected, 0);
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no nudge paid when size is zero");
    }

    function test_setNudgePaymentToken_acceptsZero() public {
        _enableNudgeFeature(NUDGE_SIZE);
        vm.prank(owner);
        batch.setNudgePaymentToken(address(0));
        assertEq(batch.nudgePaymentToken(), address(0), "token zeroed");

        uint256 N = NUDGE_SIZE; // would qualify if token were set
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));
        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no nudge paid when token is zero");
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
        batch.batchMint(N, recipient, expected, 0);

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
        batch.batchMint(N, recipient, expected, 0);

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
        batch.batchMint(N, recipient, expected, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nudgePaidSig = keccak256("NudgePaid(address,address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != nudgePaidSig, "no NudgePaid event below threshold");
        }

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "recipient unchanged below threshold");
        assertEq(nudgeToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "helper retains nudge balance");
    }

    function test_batchMint_doesNotPayWhenSizeIsZero() public {
        // Token configured + funded but size remains 0 (default).
        vm.prank(owner);
        batch.setNudgePaymentToken(address(nudgeToken));
        nudgeToken.mint(address(batch), NUDGE_FUNDED_AMOUNT);

        uint256 N = 25; // large
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no payout when size is zero");
        assertEq(nudgeToken.balanceOf(address(batch)), NUDGE_FUNDED_AMOUNT, "helper retains nudge balance");
    }

    function test_batchMint_doesNotPayWhenTokenUnset() public {
        // Size set, token unset, no relevant balance.
        vm.prank(owner);
        batch.setNudgeSize(1);

        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        // Should succeed without paying any nudge — no revert.
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);

        // Sanity: nudgeToken not configured, helper should hold none.
        assertEq(nudgeToken.balanceOf(recipient), 0, "recipient gets no nudge");
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "helper holds no nudge");
    }

    function test_batchMint_doesNotPayWhenBalanceIsZero() public {
        // Both knobs set, but no balance funded.
        vm.prank(owner);
        batch.setNudgePaymentToken(address(nudgeToken));
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);
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
        batch.batchMint(N, recipient, expected, 0);

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "recipient nudge unchanged on revert");
        assertEq(nudgeToken.balanceOf(address(batch)), batchBefore, "helper nudge balance unchanged on revert");
    }

    // ----------------------------------------------------------------
    // Up-front token-distinctness guard
    // ----------------------------------------------------------------

    function test_batchMint_revertsWhenNudgeTokenMatchesPaymentToken() public {
        // Configure nudgePaymentToken == payToken — the call's payment token.
        vm.prank(owner);
        batch.setNudgePaymentToken(address(payToken));
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);

        uint256 N = 1; // even below threshold should still revert
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        // Fund + approve; we want to assert no pull happens.
        payToken.mint(caller, expected);
        vm.prank(caller);
        payToken.approve(address(batch), expected);

        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        vm.expectRevert(BatchNFTMinter.BatchMint__NudgeTokenMatchesPaymentToken.selector);
        batch.batchMint(N, recipient, expected, 0);

        assertEq(payToken.balanceOf(caller), callerBefore, "guard fires before upfront pull");
    }

    function test_batchMint_doesNotRevertWhenNudgeTokenUnsetEvenIfPaymentMatches() public {
        // Feature off (token == address(0)); paymentToken is irrelevant.
        // The guard's `_nudgeTokenEntry != address(0)` clause should let
        // the call through without reverting.
        uint256 N = 2;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        // Sanity: nudge token unset.
        assertEq(batch.nudgePaymentToken(), address(0), "nudge token unset by default");

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);

        // Reaching this point without revert is the assertion.
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "mint succeeded with feature off");
    }

    // ----------------------------------------------------------------
    // Nudge before refund sweep ordering / event coexistence
    // ----------------------------------------------------------------

    function test_batchMint_paysNudgeBeforeRefundSweep() public {
        _enableNudgeFeature(NUDGE_SIZE);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 surplus = 7 ether;
        uint256 paid = expected + surplus;
        _fundCaller(paid, address(batch));

        uint256 callerPayBefore = payToken.balanceOf(caller);
        uint256 recipientNudgeBefore = nudgeToken.balanceOf(recipient);

        // Both events should fire — ordering is implementation detail
        // covered by the inline natspec; assert both are emitted.
        vm.expectEmit(true, true, true, true, address(batch));
        emit NudgePaid(recipient, address(nudgeToken), NUDGE_FUNDED_AMOUNT);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, 0);

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
        batch.batchMint(N, recipient, expected, 0);

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
        batch.batchMint(N, attacker, 0, 0);

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
        batch.batchMint(N, recipient, expected, 0);

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
        vm.expectRevert(BatchNFTMinter.BatchMint__MinterNotConfigured.selector);
        batch.batchMint(1, recipient, expected, 0);
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
    // The nudge-token == prime-token config invariant (dust-sweep vector) is
    // retained as a deploy-time check that owner misconfiguration reverts.
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
        vm.expectRevert(BatchNFTMinter.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(N, recipient, expected, 0);

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
        vm.expectRevert(BatchNFTMinter.BatchMint__DispatcherNotConfigured.selector);
        batch.batchMint(N, recipient, expected, 0);

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
        uint256 totalPaid = batch.batchMint(N, recipient, paid, 0);

        // The DERIVED payToken is what was pulled and swept — surplus refunded.
        assertEq(payToken.balanceOf(caller), callerBefore - expected, "derived token pulled; surplus refunded");
        assertEq(payToken.balanceOf(address(batch)), 0, "no derived-token balance left in helper");
        assertEq(totalPaid, expected, "totalPaid is dispatcher cost in the derived token");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "recipient minted via pinned dispatcher");
    }

    /// @dev Dust-sweep vector (incident §4), now a deploy-time config
    ///      invariant: with `nudgePaymentToken` set equal to the dispatcher's
    ///      derived prime token (`payToken`), the up-front distinctness guard
    ///      reverts `BatchMint__NudgeTokenMatchesPaymentToken` before any funds
    ///      move. The caller can no longer pick the payment token, so this can
    ///      only trip on owner misconfiguration — it is retained as
    ///      defense-in-depth. Pot untouched.
    function test_batchMint_nudgeTokenEqualsDerivedPrimeToken_revertsConfigInvariant() public {
        // Fund the helper with payToken (the drain target). Configure nudge in
        // payToken — i.e. equal to the dispatcher's derived prime token.
        vm.prank(owner);
        batch.setNudgePaymentToken(address(payToken));
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
        payToken.mint(address(batch), 61_297674); // the real mainnet pot size

        uint256 potBefore = payToken.balanceOf(address(batch));

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        payToken.mint(caller, expected);
        vm.prank(caller);
        payToken.approve(address(batch), expected);

        // Derived paymentToken == nudge token -> the distinctness guard reverts
        // before any funds move. Pot stays put.
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinter.BatchMint__NudgeTokenMatchesPaymentToken.selector);
        batch.batchMint(N, caller, expected, 0);

        assertEq(payToken.balanceOf(address(batch)), potBefore, "pot not swept");
        assertEq(payToken.balanceOf(caller), expected, "caller keeps its funds, no windfall");
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
        batch.batchMint(NA, attacker, attackerCost, 0);
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
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, observedPot, 0)
        );
        batch.batchMint(N, recipient, buffer, observedPot);

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
        uint256 totalPaid = batch.batchMint(N, recipient, paid, floor);

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "minted count");
        assertEq(
            nudgeToken.balanceOf(recipient), recipientNudgeBefore + NUDGE_FUNDED_AMOUNT, "full nudge paid"
        );
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
        batch.batchMint(N, recipient, expected, NUDGE_FUNDED_AMOUNT);

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
        batch.batchMint(N, recipient, expected, 0);
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore + NUDGE_FUNDED_AMOUNT, "nudge paid with floor 0");

        // Non-qualifying batch, minReward == 0 -> succeeds, no payout, no revert.
        // The price has ramped from the first batch; fund from the current price.
        uint256 NB = NUDGE_SIZE - 1;
        uint256 priceNow = nftMinter.getPrice(DISPATCHER_INDEX);
        uint256 expectedB = _expectedTotal(priceNow, GROWTH_BPS, NB);
        _fundCaller(expectedB, address(batch));
        uint256 recipientBeforeB = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(NB, recipient, expectedB, 0);
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
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, floor, 0));
        batch.batchMint(N, recipient, expected, floor);

        assertEq(payToken.balanceOf(caller), callerPayBefore, "no payment pulled when floor unmet below threshold");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), recipientNftBefore, "minted nothing when floor unmet");
    }

    /// @dev Revert carries the two error fields: `minReward` and `actualReward`.
    ///      Here the pot is partially funded below the floor, so `actualReward`
    ///      is the (non-zero) deliverable balance.
    function test_batchMint_minReward_revertCarriesFields() public {
        // Configure the feature but fund the pot below the floor we'll request.
        vm.prank(owner);
        batch.setNudgePaymentToken(address(nudgeToken));
        vm.prank(owner);
        batch.setNudgeSize(NUDGE_SIZE);
        uint256 actualPot = 123 ether;
        nudgeToken.mint(address(batch), actualPot);

        uint256 N = NUDGE_SIZE;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        uint256 floor = 200 ether; // > actualPot

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, floor, actualPot)
        );
        batch.batchMint(N, recipient, expected, floor);
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
        vm.expectRevert(BatchNFTMinter.Rescue__ZeroRecipient.selector);
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
        batch.batchMint(N, recipient, expected, 0);

        vm.prank(pauser);
        batch.unpause();
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, 0);
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "mint resumes after unpause");
    }
}

