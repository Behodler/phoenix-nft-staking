// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ITokenMinter} from "yield-claim-nft/interfaces/ITokenMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BatchNFTMinter} from "../src/BatchNFTMinter.sol";
import {MockITokenMinter} from "./mocks/MockITokenMinter.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title BatchNFTMinter functional tests + gas benchmarks
///
/// Functional tests exercise the helper against a fully mocked
/// `ITokenMinter` (`MockITokenMinter`) that pulls payment, mints into a
/// `MockERC1155`, and bumps the per-index price by `growthBasisPoints`
/// after each successful mint. Gas benchmarks compare wrapper overhead
/// (count = 1) and N-mint amortisation (N in {2, 5, 10, 25}) against
/// successive direct `nftMinter.mint(...)` calls.
contract BatchNFTMinterTest is Test {
    BatchNFTMinter internal batch;
    MockITokenMinter internal nftMinter;
    MockERC1155 internal nft;
    MockERC20 internal payToken;

    address internal caller = address(0xCAFE);
    address internal recipient = address(0xBEEF);
    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250; // 2.5% per mint

    function setUp() public virtual {
        batch = new BatchNFTMinter();
        nftMinter = new MockITokenMinter();
        nft = new MockERC1155();
        payToken = new MockERC20("PayToken", "PAY");

        nftMinter.setStakedToken(nft);
        nftMinter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
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
        uint256 totalPaid = batch.batchMint(
            ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 1, recipient
        );

        assertEq(nft.balanceOf(recipient, DISPATCHER_INDEX), 1, "recipient gets 1 NFT unit");
        assertEq(totalPaid, START_PRICE, "totalPaid equals starting price");
    }

    function test_batchMint_NIterations_mintsNUnitsToRecipient() public {
        uint256 N = 5;
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, N);
        _fundCaller(expected, address(batch));

        vm.prank(caller);
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, N, recipient);

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
        uint256 totalPaid =
            batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, N, recipient);

        uint256 callerAfter = payToken.balanceOf(caller);
        assertEq(callerBefore - callerAfter, expected, "caller balance delta = sum of growing prices");
        assertEq(totalPaid, expected, "totalPaid matches geometric sum");
    }

    function test_batchMint_revertsOnZeroCount() public {
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinter.BatchMint__ZeroCount.selector);
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 0, recipient);
    }

    function test_batchMint_revertsOnZeroRecipient() public {
        vm.prank(caller);
        vm.expectRevert(BatchNFTMinter.BatchMint__ZeroRecipient.selector);
        batch.batchMint(
            ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 1, address(0)
        );
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
        vm.expectRevert(MockITokenMinter.MockITokenMinter__ForcedRevert.selector);
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, N, recipient);

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
        uint256 totalPaid =
            batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, N, recipient);

        assertEq(totalPaid, expected, "returned totalPaid matches geometric sum");
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
            nftMinter.mint(address(payToken), DISPATCHER_INDEX, recipient);
        }
    }

    function test_gas_singleDirectMint() public {
        _fundDirect(1);
        vm.prank(caller);
        nftMinter.mint(address(payToken), DISPATCHER_INDEX, recipient);
        vm.snapshotGasLastCall("singleDirectMint");
    }

    function test_gas_batchMintCount1() public {
        uint256 expected = _expectedTotal(START_PRICE, GROWTH_BPS, 1);
        _fundCaller(expected, address(batch));
        vm.prank(caller);
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 1, recipient);
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
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 2, recipient);
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
        batch.batchMint(ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 5, recipient);
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
        batch.batchMint(
            ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 10, recipient
        );
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
        batch.batchMint(
            ITokenMinter(address(nftMinter)), IERC20(address(payToken)), DISPATCHER_INDEX, 25, recipient
        );
        vm.snapshotGasLastCall("batchMintN_25");
    }
}
