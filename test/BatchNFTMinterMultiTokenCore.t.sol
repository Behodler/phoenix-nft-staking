// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title BatchNFTMinterMultiToken functional tests + gas benchmarks
///
/// Functional tests exercise the helper against a fully mocked
/// `ITokenMinterV2` (`MockITokenMinterV2`) that pulls payment, mints into a
/// `MockERC1155`, and bumps the per-index price by `growthBasisPoints`
/// after each successful mint. Gas benchmarks compare wrapper overhead
/// (count = 1) and N-mint amortisation (N in {2, 5, 10, 25}) against
/// successive direct `nftMinter.mint(...)` calls.
contract BatchNFTMinterMultiTokenCoreTest is Test {
    BatchNFTMinterMultiToken internal batch;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;
    MockERC20 internal payToken;

    address internal owner = makeAddr("batchOwner");
    address internal pauser = makeAddr("batchPauser");
    address internal caller = address(0xCAFE);
    address internal recipient = address(0xBEEF);
    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250; // 2.5% per mint

    function setUp() public virtual {
        batch = new BatchNFTMinterMultiToken(owner);
        nftMinter = new MockITokenMinterV2();
        nft = new MockERC1155();
        payToken = new MockERC20("PayToken", "PAY");

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

    /// @notice Compute the geometric sum of N successive mint prices given
    ///         an initial price and basis-points growth factor by reading
    ///         the live mock state (mirrors how the helper accumulates).
    ///         Caller must mint funding equal to `expectedTotal` to
    ///         `caller` separately and approve `batch`/`nftMinter` for it.
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

    // ----------------------------------------------------------------
    // Functional tests
    // ----------------------------------------------------------------

    function test_batchMint_oneIteration_mintsOneUnitToRecipient() public {
        _fundCaller(START_PRICE, address(batch));

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(1, recipient, START_PRICE, new uint256[](0));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 1, "recipient gets 1 NFT unit");
        assertEq(totalPaid, START_PRICE, "totalPaid equals starting price");
    }

    function test_batchMint_revertsWhenMinterNotConfigured() public {
        // Unpin the minter; batchMint must refuse to run.
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));

        _fundCaller(START_PRICE, address(batch));
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__MinterNotConfigured.selector);
        batch.batchMint(1, recipient, START_PRICE, new uint256[](0));
    }

    function test_batchMint_revertsWhenPaused() public {
        vm.prank(owner);
        batch.setPauser(pauser);
        vm.prank(pauser);
        batch.pause();

        _fundCaller(START_PRICE, address(batch));
        vm.prank(caller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        batch.batchMint(1, recipient, START_PRICE, new uint256[](0));

        // After unpause it works again.
        vm.prank(pauser);
        batch.unpause();
        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(1, recipient, START_PRICE, new uint256[](0));
        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 1, "mint resumes after unpause");
        assertEq(totalPaid, START_PRICE, "totalPaid correct after unpause");
    }

    function test_setPauser_onlyOwner_andEmits() public {
        vm.prank(caller);
        vm.expectRevert();
        batch.setPauser(pauser);

        vm.prank(owner);
        batch.setPauser(pauser);
        assertEq(batch.pauser(), pauser, "pauser stored");
    }

    function test_pause_revertsForNonPauser() public {
        vm.prank(owner);
        batch.setPauser(pauser);

        vm.prank(caller);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.pause();

        vm.prank(caller);
        vm.expectRevert("BatchNFTMinter: caller is not pauser");
        batch.unpause();
    }

    function test_batchMint_NIterations_mintsNUnitsToRecipient() public {
        uint256 N = 5;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        batch.batchMint(N, recipient, expected, new uint256[](0));

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), N, "recipient gets N NFT units");
    }

    function test_batchMint_pullsCumulativePriceFromCaller() public {
        uint256 N = 5;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        // Fund a healthy buffer so we can detect the precise delta pulled.
        uint256 buffer = expected + 1_000 ether;
        payToken.mint(caller, buffer);
        vm.prank(caller);
        payToken.approve(address(batch), buffer);

        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, expected, new uint256[](0));

        uint256 callerAfter = payToken.balanceOf(caller);
        assertEq(callerBefore - callerAfter, expected, "caller balance delta = sum of growing prices");
        assertEq(totalPaid, expected, "totalPaid matches geometric sum");
    }

    function test_batchMint_revertsOnZeroCount() public {
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__ZeroCount.selector);
        batch.batchMint(0, recipient, 0, new uint256[](0));
    }

    function test_batchMint_revertsOnZeroRecipient() public {
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinterMultiToken.BatchMint__ZeroRecipient.selector);
        batch.batchMint(1, address(0), 0, new uint256[](0));
    }

    function test_batchMint_revertsAtomicallyOnInnerRevert() public {
        uint256 N = 5;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        // Force the 3rd inner mint call to revert.
        nftMinter.setRevertAtCall(3, true);

        uint256 callerBefore = payToken.balanceOf(caller);
        uint256 recipientBefore = nft.balanceOf(recipient, DISPATCHER_INDEX);

        vm.prank(caller);
        vm.expectRevert(MockITokenMinterV2.MockITokenMinterV2__ForcedRevert.selector);
        batch.batchMint(N, recipient, expected, new uint256[](0));

        assertEq(payToken.balanceOf(caller), callerBefore, "caller balance unchanged on revert");
        assertEq(
            nft.balanceOf(recipient, DISPATCHER_INDEX),
            recipientBefore,
            "no NFT transferred to recipient on atomic revert"
        );
    }

    function test_batchMint_returnsTotalPaid() public {
        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, expected, new uint256[](0));

        assertEq(totalPaid, expected, "returned totalPaid matches geometric sum");
    }

    function test_batchMint_refundsSurplusAboveDustThreshold() public {
        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 surplus = 7 ether; // well above 1e6 wei
        uint256 paid = expected + surplus;
        _fundCaller(paid, address(batch));

        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, new uint256[](0));

        assertEq(totalPaid, expected, "totalPaid is dispatcher cost, not paymentAmount");
        assertEq(payToken.balanceOf(caller), callerBefore - expected, "surplus refunded to caller");
        assertEq(payToken.balanceOf(address(batch)), 0, "no balance left in helper");
    }

    function test_batchMint_keepsSubThresholdDustInContract() public {
        uint256 N = 1;
        uint256 dust = 999_999; // 1 wei below threshold
        uint256 paid = START_PRICE + dust;
        _fundCaller(paid, address(batch));

        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, paid, new uint256[](0));

        assertEq(totalPaid, paid, "totalPaid swallows dust");
        assertEq(payToken.balanceOf(caller), callerBefore - paid, "no refund issued for sub-threshold");
        assertEq(payToken.balanceOf(address(batch)), dust, "dust retained in helper");
    }

    /// @dev Story-029 inverted this. The refund is now the caller's UNSPENT
    ///      BUDGET, computed from a locally-tracked counter, not a sweep of
    ///      `paymentToken.balanceOf(address(this))`. A third-party donation of
    ///      payment token is therefore NOT the caller's money and does not come
    ///      back to them as a windfall — it stays behind as pot, exactly as a
    ///      donation of any other token does.
    ///
    ///      This test previously asserted the windfall (`callerBefore - expected
    ///      + donation`). That behaviour was the mechanism behind
    ///      yield-claim-nft `ycn19h1`: once the payment token was also a nudge
    ///      token, "donation" included the entire standing nudge pot, and a
    ///      `count = 1` batch paying one wei collected it.
    function test_batchMint_donationToHelperStaysForTheNextClaimant() public {
        uint256 N = 3;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        uint256 donation = 100 ether;

        // Griefer pre-funds the helper before the call.
        payToken.mint(address(batch), donation);

        _fundCaller(expected, address(batch));
        uint256 callerBefore = payToken.balanceOf(caller);

        vm.prank(caller);
        uint256 totalPaid = batch.batchMint(N, recipient, expected, new uint256[](0));

        assertEq(
            payToken.balanceOf(caller),
            callerBefore - expected,
            "caller is charged exactly the cumulative price and refunded exactly the unspent budget (zero here)"
        );
        assertEq(
            payToken.balanceOf(address(batch)),
            donation,
            "a third-party donation is NOT the caller's budget and must stay behind as pot"
        );
        assertEq(totalPaid, expected, "totalPaid is the cumulative charge");
    }

    // ----------------------------------------------------------------
    // Gas benchmarks
    //
    // Each scenario mints fresh state in `setUp()` so prices/cold-storage
    // costs are comparable across tests. Each `_directMintN` test runs N
    // direct `nftMinter.mint` calls inside one test (single-tx context),
    // while `_batchMintN` runs one `batchMint(count = N)`. We snapshot
    // around the under-test call so gas is captured deterministically.
    // ----------------------------------------------------------------

    function _fundDirect(uint256 N) internal returns (uint256 expected) {
        expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        payToken.mint(caller, expected);
        vm.prank(caller);
        payToken.approve(address(nftMinter), expected);
    }

    function _runDirectN(uint256 N) internal {
        for (uint256 i = 0; i < N; i++) {
            vm.prank(caller);
            nftMinter.mint(DISPATCHER_INDEX, recipient);
        }
    }

    function test_gas_singleDirectMint() public {
        _fundDirect(1);
        vm.prank(caller);
        nftMinter.mint(DISPATCHER_INDEX, recipient);
        vm.snapshotGasLastCall("singleDirectMint");
    }

    function test_gas_batchMintCount1() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 1);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(1, recipient, expected, new uint256[](0));
        vm.snapshotGasLastCall("batchMintCount1");
    }

    function test_gas_directMintN_2() public {
        _fundDirect(2);
        vm.startSnapshotGas("directMintN_2");
        _runDirectN(2);
        vm.stopSnapshotGas();
    }

    function test_gas_batchMintN_2() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 2);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(2, recipient, expected, new uint256[](0));
        vm.snapshotGasLastCall("batchMintN_2");
    }

    function test_gas_directMintN_5() public {
        _fundDirect(5);
        vm.startSnapshotGas("directMintN_5");
        _runDirectN(5);
        vm.stopSnapshotGas();
    }

    function test_gas_batchMintN_5() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 5);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(5, recipient, expected, new uint256[](0));
        vm.snapshotGasLastCall("batchMintN_5");
    }

    function test_gas_directMintN_10() public {
        _fundDirect(10);
        vm.startSnapshotGas("directMintN_10");
        _runDirectN(10);
        vm.stopSnapshotGas();
    }

    function test_gas_batchMintN_10() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 10);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(10, recipient, expected, new uint256[](0));
        vm.snapshotGasLastCall("batchMintN_10");
    }

    function test_gas_directMintN_25() public {
        _fundDirect(25);
        vm.startSnapshotGas("directMintN_25");
        _runDirectN(25);
        vm.stopSnapshotGas();
    }

    function test_gas_batchMintN_25() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 25);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(25, recipient, expected, new uint256[](0));
        vm.snapshotGasLastCall("batchMintN_25");
    }

    /// @notice Capture the unhappy-path overhead added by the multi-token
    ///         nudge: `nudgeSize` configured and a reward token IS
    ///         whitelisted, but `count` is below the threshold so
    ///         `qualifies` is false. The snapshot loop still walks the
    ///         whitelist (runtime payment-token skip check per element),
    ///         skips the `balanceOf`, and the payout pass finds
    ///         `snapshot[0] == 0` and transfers nothing.
    ///
    ///         Redesigned for story-025: the reward asset is now
    ///         owner-whitelisted rather than caller-supplied, so the
    ///         equivalent unhappy path is "whitelist populated, threshold
    ///         not met".
    function test_gas_batchMintNudge_unhappyPath() public {
        // Threshold the call will not meet.
        MockERC20 nudgeToken = new MockERC20("NudgeToken", "NDG");
        vm.prank(owner);
        batch.setNudgeSize(10);
        vm.prank(owner);
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);

        // Fund the helper with nudge tokens so the pot exists in the same
        // shape the happy path would see.
        nudgeToken.mint(address(batch), 1_000 ether);

        uint256[] memory minRewards = new uint256[](1);

        uint256 N = 5; // below the threshold of 10
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, minRewards);
        vm.snapshotGasLastCall("batchMintNudge_unhappyPath");
    }

    /// @notice Multi-token payout gas: 1 / 2 / 3 whitelisted tokens on an
    ///         otherwise identical qualifying batch. The §8 acceptance
    ///         check reads the deltas between these three as the
    ///         per-additional-token cost and requires them to be LINEAR —
    ///         a superlinear trend means a dedupe or nested loop crept in
    ///         (a bug against §4.5).
    ///
    /// @dev    **Story-032 recorded a +17,000 absolute shift in all three
    ///         labels, and in `batchMintNudge_unhappyPath`. `batchMint` did not
    ///         change — do not read it as a regression.** It is a warm/cold
    ///         artifact of the HARNESS. Foundry runs a test body as one
    ///         transaction, so the `setNudgeTokenWhitelist` calls above used to
    ///         pre-warm `tokenMinter`, `dispatcherIndex`, the minter and
    ///         dispatcher accounts and `primeToken` on `batchMint`'s behalf, via
    ///         the `_resolvePaymentPath()` call in the add branch. Story-032
    ///         removed that derivation, so `batchMint` now pays the cold-access
    ///         cost itself — exactly as it always did in production, where no
    ///         whitelist call precedes it in the same transaction. Warming those
    ///         four reads back up before the call reproduces the old figures to
    ///         the wei. The DELTAS between the three labels — the linearity this
    ///         benchmark actually pins — are unchanged, and the cold-path
    ///         `batchMintCount1` / `batchMintN_*` figures did not move at all.
    function _gasMultiToken(uint256 tokenCount, string memory label) internal {
        vm.prank(owner);
        batch.setNudgeSize(2);

        uint256[] memory minRewards = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            MockERC20 rewardToken = new MockERC20("Reward", "RWD");
            rewardToken.mint(address(batch), 1_000 ether);
            vm.prank(owner);
            batch.setNudgeTokenWhitelist(address(rewardToken), true);
        }

        uint256 N = 2;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(N, recipient, expected, minRewards);
        vm.snapshotGasLastCall(label);
    }

    function test_gas_batchMintMultiToken_1() public {
        _gasMultiToken(1, "batchMintMultiToken_1");
    }

    function test_gas_batchMintMultiToken_2() public {
        _gasMultiToken(2, "batchMintMultiToken_2");
    }

    function test_gas_batchMintMultiToken_3() public {
        _gasMultiToken(3, "batchMintMultiToken_3");
    }
}
