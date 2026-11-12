// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {NudgeStreamer} from "../src/NudgeStreamer.sol";
import {NudgeDiscountFixture} from "./BatchNFTMinterNudgeDiscount.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title BatchNFTMinterNudgeDiscount — integration with the REAL `NudgeStreamer` (story 033)
///
/// The discount pot is fed by a linear USDC stream. `batchMint` must flush every whitelisted
/// stream (discount token included) BEFORE it reads the pot (ordering (c)), so the batch size
/// reflects the settled amount; and anything streamed after a batch lands in the LIVE pot, never
/// in the reserve.
contract BatchNFTMinterNudgeDiscountStreamTest is NudgeDiscountFixture {
    NudgeStreamer internal streamer;
    address internal donor = makeAddr("donor");

    uint256 internal constant USDC_DURATION = 10 days;
    uint256 internal constant BONUS_DURATION = 30 days;

    function setUp() public override {
        super.setUp();
        streamer = new NudgeStreamer(owner);
        vm.startPrank(owner);
        batch.setNudgeStreamer(address(streamer));
        streamer.registerStream(address(batch), address(usdc), USDC_DURATION);
        streamer.registerStream(address(batch), address(phUSD), BONUS_DURATION);
        streamer.registerStream(address(batch), address(kendu), BONUS_DURATION);
        vm.stopPrank();

        usdc.mint(donor, 1_000_000e6);
        phUSD.mint(donor, 1_000_000e18);
        kendu.mint(donor, 1_000_000e18);
        vm.startPrank(donor);
        usdc.approve(address(streamer), type(uint256).max);
        phUSD.approve(address(streamer), type(uint256).max);
        kendu.approve(address(streamer), type(uint256).max);
        vm.stopPrank();
    }

    function _donate(address token, uint256 amount) internal {
        vm.prank(donor);
        streamer.collectNudge(address(batch), token, amount);
    }

    function test_RegisterStream_acceptsWhitelistedDiscountToken_rejectsOthers() public {
        MockERC20 stray = new MockERC20("S", "S");
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(NudgeStreamer.NudgeStreamer__NotWhitelisted.selector, address(batch), address(stray))
        );
        streamer.registerStream(address(batch), address(stray), USDC_DURATION);
        // USDC was registered in setUp (it is whitelisted while being the discount token).
        (uint256 duration,,,) = streamer.streams(address(batch), address(usdc));
        assertEq(duration, USDC_DURATION);
    }

    function test_StreamSettlesBeforePotRead_previewMatches() public {
        _donate(address(usdc), 100e6);
        vm.warp(block.timestamp + 5 days);

        uint256 pending = streamer.pendingStream(address(batch), address(usdc));
        assertGt(pending, 40e6);
        assertEq(usdc.balanceOf(address(batch)), 0, "nothing has landed yet: only the flush can make free > 0");

        (uint256 free, uint256 total, uint256 paid, uint256 paidCost, uint256 owed, uint256 potUSD,) =
            batch.previewBatch();
        assertEq(potUSD, pending * CONV, "preview counts the pending stream");
        assertEq(free, (pending * CONV) / P0);

        vm.prank(caller);
        (uint256 totalPaid, uint256 f, uint256 p) =
            batch.batchMint(total, 0, recipient, paidCost, _bonusTokens(), _zeros());
        assertEq(f, free, "free reflects the settled stream");
        assertEq(p, paid);
        assertEq(totalPaid, paidCost);
        assertEq(batch.pendingBuyUSDC(), pending, "the settled amount is the reserved pot");
        assertEq(batch.pendingStakerPhUSD(), owed);
        assertEq(streamer.pendingStream(address(batch), address(usdc)), 0, "stream fully settled");
    }

    function test_PostBatchStreamFeedsLivePot_notReserve() public {
        _donate(address(usdc), 100e6);
        vm.warp(block.timestamp + 5 days);
        _batch();
        uint256 reserved = batch.pendingBuyUSDC();

        vm.warp(block.timestamp + 2 days);
        uint256 pending = streamer.pendingStream(address(batch), address(usdc));
        assertGt(pending, 0);
        (,,,,, uint256 potUSD,) = batch.previewBatch();
        assertEq(potUSD, pending * CONV, "only the new stream is pot; the reserve is excluded");
        assertEq(batch.pendingBuyUSDC(), reserved, "reserve unchanged by accrual");

        _batch();
        assertEq(batch.pendingBuyUSDC(), reserved + pending, "the next batch reserves the new stream");
        assertEq(usdc.balanceOf(address(batch)), reserved + pending);
    }

    function test_BonusStreamsFlushAndPayOnEveryBatch() public {
        _donate(address(usdc), 100e6);
        _donate(address(phUSD), 300e18);
        _donate(address(kendu), 600e18);
        vm.warp(block.timestamp + 3 days);

        uint256 phPending = streamer.pendingStream(address(batch), address(phUSD));
        uint256 kPending = streamer.pendingStream(address(batch), address(kendu));
        assertGt(phPending, 0);
        assertGt(kPending, 0);

        _batch();
        assertEq(phUSD.balanceOf(recipient), phPending, "phUSD stream flushed and paid as bonus");
        assertEq(kendu.balanceOf(recipient), kPending, "Kendu stream flushed and paid as bonus");

        // And again on the very next (small) batch — no threshold. Top the pot up directly so
        // the second batch is about the bonus, not about how much USDC one more day streams.
        vm.warp(block.timestamp + 1 days);
        _fundPot(20e6);
        uint256 phPending2 = streamer.pendingStream(address(batch), address(phUSD));
        uint256 kPending2 = streamer.pendingStream(address(batch), address(kendu));
        _batch();
        assertEq(phUSD.balanceOf(recipient), phPending + phPending2);
        assertEq(kendu.balanceOf(recipient), kPending + kPending2);
        assertEq(usdc.balanceOf(recipient), 0, "the discount token is never a bonus");
    }
}
