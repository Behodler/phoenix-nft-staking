// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterMultiToken} from "../src/BatchNFTMinterMultiToken.sol";
import {NudgeStreamer} from "../src/NudgeStreamer.sol";
import {MockITokenMinterV2} from "./mocks/MockITokenMinterV2.sol";
import {MockTokenDispatcherV2} from "./mocks/MockTokenDispatcherV2.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNudgeDonor} from "./mocks/MockNudgeDonor.sol";

/// @title BatchNFTMinterMultiToken — NudgeStreamer integration
///
/// Proves that when a `NudgeStreamer` is wired via `setNudgeStreamer`,
/// `batchMint` flushes each whitelisted token's accrued stream INTO the pot
/// (via `pullPendingStream`) BEFORE it snapshots balances, so the streamed
/// funds are counted for the current mint; and that with
/// `nudgeStreamer == address(0)` behaviour is unchanged.
contract BatchNFTMinterMultiTokenNudgeStreamTest is Test {
    BatchNFTMinterMultiToken internal batch;
    NudgeStreamer internal streamer;
    MockITokenMinterV2 internal nftMinter;
    MockTokenDispatcherV2 internal dispatcher;
    MockERC1155 internal nft;
    MockERC20 internal payToken;
    MockERC20 internal nudgeToken;
    MockNudgeDonor internal donor;

    address internal owner = makeAddr("batchOwner");
    address internal caller = address(0xCAFE);
    address internal recipient = address(0xBEEF);

    uint256 internal constant DISPATCHER_INDEX = 7;
    uint256 internal constant START_PRICE = 1_000 ether;
    uint256 internal constant GROWTH_BPS = 250;
    uint256 internal constant NUDGE_SIZE = 5;

    uint256 internal constant STREAM_DURATION = 1000;
    uint256 internal constant DONATION = 10_000 ether;

    event NudgeStreamerChanged(address indexed previousStreamer, address indexed newStreamer);

    function setUp() public {
        batch = new BatchNFTMinterMultiToken(owner);
        streamer = new NudgeStreamer(owner);
        nftMinter = new MockITokenMinterV2();
        nft = new MockERC1155();
        payToken = new MockERC20("PayToken", "PAY");
        nudgeToken = new MockERC20("NudgeToken", "NDG");
        donor = new MockNudgeDonor();
        dispatcher = new MockTokenDispatcherV2(address(payToken));

        nftMinter.setStakedToken(nft);
        nftMinter.setConfig(DISPATCHER_INDEX, START_PRICE, GROWTH_BPS);
        nftMinter.setPrimeToken(DISPATCHER_INDEX, address(payToken));
        nftMinter.setDispatcher(DISPATCHER_INDEX, address(dispatcher));

        vm.startPrank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(nftMinter)));
        batch.setDispatcherIndex(DISPATCHER_INDEX);
        batch.setNudgeSize(NUDGE_SIZE);
        batch.setNudgeTokenWhitelist(address(nudgeToken), true);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _expectedTotal(uint256 count) internal pure returns (uint256 total) {
        uint256 price = START_PRICE;
        for (uint256 i = 0; i < count; i++) {
            total += price;
            price = price * (10_000 + GROWTH_BPS) / 10_000;
        }
    }

    function _fundCaller(uint256 amount) internal {
        payToken.mint(caller, amount);
        vm.prank(caller);
        payToken.approve(address(batch), amount);
    }

    function _mins1(uint256 minReward) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = minReward;
    }

    /// @dev Register the stream and seed it with a donation via the mock donor.
    function _wireAndDonate() internal {
        vm.prank(owner);
        batch.setNudgeStreamer(address(streamer));
        vm.prank(owner);
        streamer.registerStream(address(batch), address(nudgeToken), STREAM_DURATION);

        nudgeToken.mint(address(donor), DONATION);
        donor.donate(address(streamer), address(batch), address(nudgeToken), DONATION);
    }

    // =====================================================================
    // Tests
    // =====================================================================

    function test_batchMint_flushesAccruedStreamIntoPotBeforeSnapshot() public {
        _wireAndDonate();

        // Half the window elapses: 50% of the donation is claimable from the stream.
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 expectedStreamed = DONATION / 2;
        assertEq(
            streamer.pendingStream(address(batch), address(nudgeToken)),
            expectedStreamed,
            "half the donation accrued in the streamer"
        );

        // The batchMinter holds NO nudge token yet — it is all in the streamer.
        assertEq(nudgeToken.balanceOf(address(batch)), 0, "pot empty before flush");

        uint256 N = NUDGE_SIZE;
        uint256 payment = _expectedTotal(N);
        _fundCaller(payment);

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);

        vm.prank(caller);
        batch.batchMint(N, recipient, payment, _mins1(0));

        // The flush pulled the accrued stream into the pot, which was then paid
        // out to the recipient as the nudge — so it was counted for this mint.
        assertEq(
            nudgeToken.balanceOf(recipient) - recipientBefore,
            expectedStreamed,
            "streamed funds counted in the nudge payout"
        );
        // The un-streamed remainder stays in the streamer for future batches.
        assertEq(
            streamer.pendingStream(address(batch), address(nudgeToken)),
            0,
            "accrued portion consumed by the flush"
        );
        assertEq(nudgeToken.balanceOf(address(streamer)), DONATION - expectedStreamed, "remainder still buffered");
    }

    function test_batchMint_belowThresholdFlushesButDoesNotPayOut() public {
        _wireAndDonate();
        vm.warp(block.timestamp + STREAM_DURATION / 2);
        uint256 expectedStreamed = DONATION / 2;

        // Below the nudge threshold: the flush still lands funds in the pot (so
        // they seed the next qualifying caller), but nothing is paid out now.
        uint256 N = NUDGE_SIZE - 1;
        uint256 payment = _expectedTotal(N);
        _fundCaller(payment);

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);
        vm.prank(caller);
        batch.batchMint(N, recipient, payment, _mins1(0));

        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no payout below threshold");
        assertEq(nudgeToken.balanceOf(address(batch)), expectedStreamed, "flushed stream retained in the pot");
    }

    function test_batchMint_withStreamerDisabled_behaviourUnchanged() public {
        // Register + donate to the streamer, but DO NOT wire it into the batch
        // (nudgeStreamer stays address(0)).
        vm.prank(owner);
        streamer.registerStream(address(batch), address(nudgeToken), STREAM_DURATION);
        nudgeToken.mint(address(donor), DONATION);
        donor.donate(address(streamer), address(batch), address(nudgeToken), DONATION);

        assertEq(batch.nudgeStreamer(), address(0), "streamer disabled");

        vm.warp(block.timestamp + STREAM_DURATION / 2);

        uint256 N = NUDGE_SIZE;
        uint256 payment = _expectedTotal(N);
        _fundCaller(payment);

        uint256 recipientBefore = nudgeToken.balanceOf(recipient);
        vm.prank(caller);
        batch.batchMint(N, recipient, payment, _mins1(0));

        // No flush occurred: the pot was empty, so no nudge was paid, and the
        // streamer still holds the entire donation.
        assertEq(nudgeToken.balanceOf(recipient), recipientBefore, "no streamed funds counted when disabled");
        assertEq(nudgeToken.balanceOf(address(streamer)), DONATION, "streamer untouched when disabled");
    }

    function test_setNudgeStreamer_emitsAndStores() public {
        vm.expectEmit(true, true, false, false, address(batch));
        emit NudgeStreamerChanged(address(0), address(streamer));
        vm.prank(owner);
        batch.setNudgeStreamer(address(streamer));
        assertEq(batch.nudgeStreamer(), address(streamer), "streamer stored");

        // address(0) disables again.
        vm.prank(owner);
        batch.setNudgeStreamer(address(0));
        assertEq(batch.nudgeStreamer(), address(0), "streamer cleared");
    }
}
