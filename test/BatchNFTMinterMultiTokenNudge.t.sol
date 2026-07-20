// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinter} from "../src/BatchNFTMinter.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockReentrantERC20} from "./mocks/MockReentrantERC20.sol";

/// @title BatchNFTMinter — caller-selected multi-token nudge
///
/// The full §6 test plan from `docs/multi-token-nudge.md`. The owner keeps
/// control of ELIGIBILITY (`nudgeSize`); the CALLER declares which ERC20
/// balances held by the contract they want to be paid in (`rewardTokens`)
/// and a per-token floor (`minRewards`).
///
/// The suite is organised by the invariant each group pins:
///   §4.1  payment-token exclusion (unconditional, pre-funds-moving)
///   §4.2  snapshot BEFORE the mint loop ("donate forward")
///   §4.3  reentrancy guard
///   §4.4  fee-on-transfer is documented, not defended
///   §4.5  malformed arrays are the caller's problem (no dedupe)
contract BatchNFTMinterMultiTokenNudgeTest is Test {
    BatchNFTMinter internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;

    MockERC20 internal payToken;
    MockERC20 internal rewardA; // "USDC"
    MockERC20 internal rewardB; // "WBTC"
    MockERC20 internal rewardC; // present on the contract, never requested

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

    /// @dev Mirrors `BatchNFTMinter.DUST_THRESHOLD` (internal there).
    uint256 internal constant DUST_THRESHOLD = 1e6;

    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);

    function setUp() public {
        batch = new BatchNFTMinter(owner);
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

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _arr(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    function _arr(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
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

    function _none() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _noMins() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // ================================================================ //
    // §4.1 — payment-token exclusion
    // ================================================================ //

    /// @dev 1. The derived payment token is never a legal reward token.
    function test_RevertWhen_RewardTokenIsPaymentToken() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardTokenIsPaymentToken.selector, address(payToken))
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(payToken)), _mins(0));
    }

    /// @dev 2. The check runs on EVERY element, not just the first — here the
    ///      offending entry is the third of three.
    function test_RevertWhen_RewardTokenIsPaymentTokenAmongOthers() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardTokenIsPaymentToken.selector, address(payToken))
        );
        batch.batchMint(
            NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardB), address(payToken)), _mins(0, 0, 0)
        );
    }

    /// @dev 3. The exclusion is UNCONDITIONAL: it must fire even when
    ///      `qualifies` is false, so a cheap sub-threshold call cannot be used
    ///      to probe the contract's payment-token balance.
    function test_RevertWhen_RewardTokenIsPaymentToken_EvenWhenNotQualifying() public {
        _fundPots();
        uint256 belowThreshold = NUDGE_SIZE - 1;
        uint256 cost = _costNow(belowThreshold);
        _fund(caller, cost);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardTokenIsPaymentToken.selector, address(payToken))
        );
        batch.batchMint(belowThreshold, recipient, cost, _arr(address(payToken)), _mins(0));
    }

    /// @dev 4. Sub-threshold payment-token dust left by a prior batch is not
    ///      claimable as "reward" — listing the payment token reverts — and it
    ///      continues to be swept by the normal dust mechanism instead.
    function test_PaymentTokenDustNotClaimableAsReward() public {
        _fundPots();

        // Batch 1 leaves sub-threshold dust behind.
        uint256 dust = DUST_THRESHOLD - 1;
        uint256 cost1 = _costNow(1);
        _fund(caller, cost1 + dust);
        vm.prank(caller);
        batch.batchMint(1, recipient, cost1 + dust, _none(), _noMins());
        assertEq(payToken.balanceOf(address(batch)), dust, "sub-threshold dust retained");

        // The dust cannot be requested as a reward.
        uint256 cost2 = _costNow(NUDGE_SIZE);
        _fund(caller2, cost2);
        vm.prank(caller2);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinter.BatchMint__RewardTokenIsPaymentToken.selector, address(payToken))
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost2, _arr(address(payToken)), _mins(0));
        assertEq(payToken.balanceOf(address(batch)), dust, "dust survives the attempted claim");

        // It is still swept normally by a batch that leaves a supra-threshold
        // surplus: the sweep pays out `dust + surplus` to msg.sender.
        uint256 surplus = 5 ether;
        _fund(caller2, cost2 + surplus);
        uint256 caller2Before = payToken.balanceOf(caller2);
        vm.prank(caller2);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost2 + surplus, _arr(address(rewardA)), _mins(0));

        assertEq(payToken.balanceOf(address(batch)), 0, "dust swept with the surplus");
        assertEq(
            payToken.balanceOf(caller2), caller2Before - cost2 + dust, "caller receives surplus plus the prior dust"
        );
        assertEq(totalPaid, (cost2 + surplus) - (surplus + dust), "totalPaid nets out the swept dust");
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
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0, 0));

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
        uint256 donationA = 3e6;
        rewardA.mint(address(nftMinter), donationA * NUDGE_SIZE * 2);
        nftMinter.setPerMintDonation(address(rewardA), donationA);

        // Batch 1: contract starts empty, so this batcher earns nothing.
        uint256 cost1 = _costNow(NUDGE_SIZE);
        _fund(caller, cost1);
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost1, _arr(address(rewardA)), _mins(0));
        assertEq(rewardA.balanceOf(recipient), 0, "first batcher into an empty pot earns nothing");
        assertEq(rewardA.balanceOf(address(batch)), donationA * NUDGE_SIZE, "batch 1 donations accumulate");

        // Batch 2: paid exactly what batch 1 left behind.
        address recipient2 = makeAddr("recipient2");
        uint256 cost2 = _costNow(NUDGE_SIZE);
        _fund(caller2, cost2);
        vm.prank(caller2);
        batch.batchMint(NUDGE_SIZE, recipient2, cost2, _arr(address(rewardA)), _mins(0));

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

    /// @dev 7. A caller-supplied "reward token" that reenters `batchMint` from
    ///      its `transfer` hook must be stopped by `nonReentrant`.
    function test_RevertWhen_RewardTokenReentersBatchMint() public {
        MockReentrantERC20 evil = new MockReentrantERC20("Evil", "EVL");
        evil.mint(address(batch), 1_000 ether);

        uint256 cost = _costNow(NUDGE_SIZE);
        // Fund generously: the nested frame would also try to pull payment.
        _fund(caller, cost * 4);

        evil.arm(address(batch), NUDGE_SIZE, recipient, cost);

        vm.prank(caller);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(evil)), _mins(0));

        assertEq(evil.balanceOf(recipient), 0, "no reward delivered on the reentrant path");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "batch rolled back atomically");
    }

    // ================================================================ //
    // Multi-token payout
    // ================================================================ //

    /// @dev 8. Both requested balances are delivered in full.
    function test_PaysAllRequestedTokens() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), POT_A, "full rewardA pot delivered");
        assertEq(rewardB.balanceOf(recipient), POT_B, "full rewardB pot delivered");
        assertEq(rewardA.balanceOf(address(batch)), 0, "rewardA drained");
        assertEq(rewardB.balanceOf(address(batch)), 0, "rewardB drained");
    }

    /// @dev 9. A token the contract holds but the caller did NOT list is
    ///      untouched — the caller declares the payout set, nothing else.
    function test_PaysOnlyRequestedTokens() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0, 0));

        assertEq(rewardC.balanceOf(recipient), 0, "unlisted token never leaves the contract");
        assertEq(rewardC.balanceOf(address(batch)), POT_C, "unlisted token pot intact");
    }

    /// @dev 10. Empty arrays are legal and mean "no reward wanted".
    function test_EmptyArraysMintWithoutReward() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(NUDGE_SIZE, recipient, cost, _none(), _noMins());

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "mints still happen");
        assertEq(totalPaid, cost, "totalPaid unaffected");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A untouched");
        assertEq(rewardB.balanceOf(address(batch)), POT_B, "pot B untouched");
        _assertNoNudgePaid();
    }

    /// @dev 11. A listed token the contract holds none of is a silent no-op:
    ///      no transfer, no event, no revert (given `min == 0`).
    function test_ZeroBalanceTokenIsNoOp() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");
        rewardA.mint(address(batch), POT_A);

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(emptyToken)), _mins(0));

        assertEq(emptyToken.balanceOf(recipient), 0, "nothing delivered for an empty pot");
        _assertNoNudgePaid();
    }

    /// @dev 12. `NudgePaid` fires once per token ACTUALLY transferred — so the
    ///      zero-balance entry in the middle produces no event.
    function test_EmitsNudgePaidPerToken() public {
        _fundPots();
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(
            NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(emptyToken), address(rewardB)), _mins(0, 0, 0)
        );

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

    // ================================================================ //
    // Floors
    // ================================================================ //

    /// @dev 13. A breached floor anywhere in the array reverts the whole batch,
    ///      naming the offending token, its floor and the actual balance.
    function test_RevertWhen_AnyMinRewardExceedsBalance() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);

        // First element breached.
        _fund(caller, cost);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, address(rewardA), POT_A + 1, POT_A
            )
        );
        batch.batchMint(
            NUDGE_SIZE,
            recipient,
            cost,
            _arr(address(rewardA), address(rewardB), address(rewardC)),
            _mins(POT_A + 1, 0, 0)
        );

        // Middle element breached.
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, address(rewardB), POT_B + 1, POT_B
            )
        );
        batch.batchMint(
            NUDGE_SIZE,
            recipient,
            cost,
            _arr(address(rewardA), address(rewardB), address(rewardC)),
            _mins(0, POT_B + 1, 0)
        );

        // Last element breached.
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, address(rewardC), POT_C + 1, POT_C
            )
        );
        batch.batchMint(
            NUDGE_SIZE,
            recipient,
            cost,
            _arr(address(rewardA), address(rewardB), address(rewardC)),
            _mins(0, 0, POT_C + 1)
        );

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "no mints survived any floor breach");
    }

    /// @dev 14. All-zero floors never revert — including when nothing at all is
    ///      deliverable (empty pots, or a non-qualifying batch).
    function test_ZeroMinRewardsNeverRevert() public {
        MockERC20 emptyToken = new MockERC20("Empty", "EMT");

        // Qualifying batch, every pot empty.
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(emptyToken)), _mins(0, 0));
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE, "qualifying zero-floor batch succeeded");

        // Non-qualifying batch, pots funded.
        _fundPots();
        uint256 below = NUDGE_SIZE - 1;
        uint256 cost2 = _costNow(below);
        _fund(caller, cost2);
        vm.prank(caller);
        batch.batchMint(below, recipient, cost2, _arr(address(rewardA), address(rewardB)), _mins(0, 0));
        assertEq(
            nft.balanceOf(recipient, DISPATCHER_INDEX), NUDGE_SIZE + below, "non-qualifying zero-floor batch succeeded"
        );
    }

    /// @dev 15. §3 step 4 runs BEFORE step 5's `safeTransferFrom`. Proven by
    ///      giving the caller funds but NO allowance: if the floor check ran
    ///      after the pull, the revert would be an allowance failure. It is the
    ///      floor error, so the check is genuinely pre-pull.
    function test_FloorCheckedBeforePaymentPull() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        payToken.mint(caller, cost); // funded but deliberately NOT approved
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinter.BatchMint__RewardBelowMinimum.selector, address(rewardA), POT_A + 1, POT_A
            )
        );
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA)), _mins(POT_A + 1));

        assertEq(payToken.balanceOf(caller), callerBefore, "caller's payment token untouched on a floor revert");
        assertEq(payToken.balanceOf(address(batch)), 0, "nothing was pulled into the contract");
    }

    /// @dev 16. Length equality is one of only two things the contract
    ///      validates about the arrays.
    function test_RevertWhen_ArrayLengthMismatch() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinter.BatchMint__ArrayLengthMismatch.selector, 2, 1));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinter.BatchMint__ArrayLengthMismatch.selector, 1, 2));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA)), _mins(0, 0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinter.BatchMint__ArrayLengthMismatch.selector, 0, 1));
        batch.batchMint(NUDGE_SIZE, recipient, cost, _none(), _mins(0));
    }

    // ================================================================ //
    // Eligibility (owner-controlled)
    // ================================================================ //

    /// @dev 17. Arrays supplied but `count < nudgeSize` — nothing is paid and
    ///      the call still succeeds.
    function test_NoRewardWhenCountBelowNudgeSize() public {
        _fundPots();
        uint256 below = NUDGE_SIZE - 1;
        uint256 cost = _costNow(below);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(below, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), 0, "no reward below the threshold");
        assertEq(rewardB.balanceOf(recipient), 0, "no reward below the threshold");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A intact");
        _assertNoNudgePaid();
    }

    /// @dev 18. `nudgeSize == 0` disables the incentive entirely — the owner's
    ///      one remaining lever.
    function test_NoRewardWhenNudgeSizeZero() public {
        _fundPots();
        vm.prank(owner);
        batch.setNudgeSize(0);

        uint256 count = 25;
        uint256 cost = _costNow(count);
        _fund(caller, cost);

        vm.recordLogs();
        vm.prank(caller);
        batch.batchMint(count, recipient, cost, _arr(address(rewardA), address(rewardB)), _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), 0, "no reward when nudgeSize is zero");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot A intact when nudgeSize is zero");
        _assertNoNudgePaid();
    }

    // ================================================================ //
    // Documented-behaviour witnesses (§4.4 / §4.5)
    // ================================================================ //

    /// @dev 19. §4.4 witness. `minRewards[i]` is a floor on the CONTRACT'S
    ///      PRE-TRANSFER BALANCE, not on what `recipient` receives. A
    ///      fee-on-transfer token therefore clears the floor and still delivers
    ///      below it — documented, deliberately not defended. If this test ever
    ///      starts failing, someone added balance-delta measurement and §4.4
    ///      must be rewritten before the change lands.
    function test_FeeOnTransferDeliversBelowMinReward() public {
        MockFeeOnTransferERC20 taxed = new MockFeeOnTransferERC20("Taxed", "TAX", 500); // 5%
        uint256 pot = 1_000 ether;
        taxed.mint(address(batch), pot);

        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);

        // Floor set to the FULL pot — the snapshot equals it, so no revert.
        vm.prank(caller);
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(taxed)), _mins(pot));

        uint256 delivered = taxed.balanceOf(recipient);
        assertEq(delivered, pot - (pot * 500) / 10_000, "recipient receives the post-fee amount");
        assertLt(delivered, pot, unicode"§4.4: delivered amount is BELOW the declared floor and that is by design");
        assertEq(taxed.balanceOf(address(batch)), 0, "contract's whole snapshot left the contract");
    }

    /// @dev 20. §4.5 witness. Duplicate entries both snapshot the same balance;
    ///      the first transfer drains it and the second fails on insufficient
    ///      balance. The batch rolls back — it fails CLOSED, harming only the
    ///      careless caller. This is why there is no O(n^2) dedupe pass.
    function test_DuplicateRewardTokenFailsClosed() public {
        _fundPots();
        uint256 cost = _costNow(NUDGE_SIZE);
        _fund(caller, cost);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        vm.expectRevert(); // ERC20InsufficientBalance from the second transfer
        batch.batchMint(NUDGE_SIZE, recipient, cost, _arr(address(rewardA), address(rewardA)), _mins(0, 0));

        assertEq(rewardA.balanceOf(recipient), 0, "duplicate entry pays nothing");
        assertEq(rewardA.balanceOf(address(batch)), POT_A, "pot intact after the failed-closed batch");
        assertEq(payToken.balanceOf(caller), callerBefore, "caller's payment rolled back");
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 0, "no mints survived");
    }

    // ================================================================ //
    // Fuzz
    // ================================================================ //

    /// @dev 21. The §4.6 sweep / `totalPaid` invariant holds for arbitrary
    ///      `count`, `paymentAmount` surplus and reward-array shape:
    ///        - surplus >= DUST_THRESHOLD  -> refunded, `totalPaid == cost`
    ///        - surplus <  DUST_THRESHOLD  -> retained, `totalPaid == paymentAmount`
    ///      and the reward payout never perturbs either side of that ledger.
    function testFuzz_TotalPaidAccounting(uint256 count, uint256 surplus, uint8 shape) public {
        count = bound(count, 1, 8);
        surplus = bound(surplus, 0, 10 ether);
        uint256 numTokens = bound(uint256(shape), 0, 3);

        address[] memory tokens = new address[](numTokens);
        uint256[] memory minRewards = new uint256[](numTokens);
        MockERC20[3] memory pool = [rewardA, rewardB, rewardC];
        uint256[3] memory pots = [POT_A, POT_B, POT_C];
        for (uint256 i = 0; i < numTokens; i++) {
            pool[i].mint(address(batch), pots[i]);
            tokens[i] = address(pool[i]);
        }

        uint256 cost = _costNow(count);
        uint256 paymentAmount = cost + surplus;
        _fund(caller, paymentAmount);
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(count, recipient, paymentAmount, tokens, minRewards);

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
