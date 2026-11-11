// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

import {BatchNFTMinterNudgeDiscount} from "../src/BatchNFTMinterNudgeDiscount.sol";
import {ISkyPSM} from "../src/interfaces/ISkyPSM.sol";
import {NudgeDiscountFixture} from "./BatchNFTMinterNudgeDiscount.t.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockSUSDS} from "./mocks/MockSUSDS.sol";

/// @title BatchNFTMinterNudgeDiscount — deferred `buyAndBurn` unit tests (story 033)
contract BatchNFTMinterNudgeDiscountBuyTest is NudgeDiscountFixture {
    event BoughtAndBurned(
        address indexed buyer,
        uint256 usdcIn,
        uint256 phusdOut,
        uint256 toStakerOwed,
        uint256 toStakerExtra,
        uint256 burned,
        uint256 owedRemaining
    );

    address internal whale = makeAddr("whale");

    /// @dev Reserve `pot` USDC through a real batch (owed = free * P0 * 50 / 100).
    function _reserve(uint256 pot) internal {
        _fundPot(pot);
        _batch();
    }

    /// @dev Expected phUSD out for `usdcIn` along PSM -> sUSDS -> pair, from live state.
    function _quoteOut(uint256 usdcIn) internal view returns (uint256) {
        uint256 usdsOut = usdcIn * CONV - (usdcIn * CONV * psm.tin()) / 1e18;
        uint256 shares = sUSDS.convertToShares(usdsOut);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rIn, uint256 rOut) = pair.token0() == address(sUSDS) ? (r0, r1) : (r1, r0);
        return router.getAmountOut(shares, rIn, rOut);
    }

    /// @dev Push phUSD's price up (sUSDS in, phUSD out) or down (phUSD in) via the router.
    function _rally(uint256 sUsdsIn) internal {
        usds.mint(whale, sUsdsIn);
        vm.startPrank(whale);
        usds.approve(address(sUSDS), sUsdsIn);
        uint256 shares = sUSDS.deposit(sUsdsIn, whale);
        IERC20(address(sUSDS)).approve(address(router), shares);
        address[] memory path = new address[](2);
        path[0] = address(sUSDS);
        path[1] = address(phUSD);
        router.swapExactTokensForTokens(shares, 1, path, whale, block.timestamp);
        vm.stopPrank();
    }

    function _crash(uint256 phusdIn) internal {
        phUSD.mint(whale, phusdIn);
        vm.startPrank(whale);
        phUSD.approve(address(router), phusdIn);
        address[] memory path = new address[](2);
        path[0] = address(phUSD);
        path[1] = address(sUSDS);
        router.swapExactTokensForTokens(phusdIn, 1, path, whale, block.timestamp);
        vm.stopPrank();
    }

    function _buy(uint256 usdcIn) internal returns (uint256 out, uint256 toStaker, uint256 burned) {
        vm.prank(buyer);
        return batch.buyAndBurn(usdcIn, 1, block.timestamp);
    }

    // =====================================================================
    // 1. Split at burnPercent 0 / 50 / 100
    // =====================================================================

    function _assertSplit(uint8 burnPct) internal {
        vm.prank(owner);
        batch.setBurnPercent(burnPct);
        _reserve(10e6); // owed 5e18
        uint256 owed = batch.pendingStakerPhUSD();
        assertEq(owed, 5e18);

        uint256 expectedOut = _quoteOut(10e6);
        uint256 supplyBefore = phUSD.totalSupply();
        (uint256 out, uint256 toStaker, uint256 burned) = _buy(10e6);

        assertEq(out, expectedOut, "phusdOut matches the route quote");
        assertGt(out, owed, "this fixture prices phUSD at ~$1, so there is extra");
        uint256 extra = out - owed;
        assertEq(burned, (extra * burnPct) / 100, "burned floors");
        assertEq(toStaker, owed + extra - burned, "NFTStaker gets owed + extra - burned");
        assertEq(phUSD.balanceOf(nftStaker), toStaker);
        assertEq(supplyBefore - phUSD.totalSupply(), burned, "supply drops by exactly burned");
        assertEq(out, toStaker + burned, "phusdOut == toStaker + burned");
        assertEq(batch.pendingStakerPhUSD(), 0, "owed fully paid");
        assertEq(batch.pendingBuyUSDC(), 0);
        assertEq(phUSD.balanceOf(address(batch)), 0, "no bought phUSD stays behind");
        assertEq(usdc.balanceOf(address(batch)), 0, "USDC fully spent");
        assertEq(phUSD.allowance(address(batch), address(batch)), 0, "self-allowance exact and consumed");
        assertEq(usdc.allowance(address(batch), address(psm)), 0);
        assertEq(usds.allowance(address(batch), address(sUSDS)), 0);
        assertEq(IERC20(address(sUSDS)).allowance(address(batch), address(router)), 0);
    }

    function test_Split_burn0() public {
        _assertSplit(0);
    }

    function test_Split_burn50() public {
        _assertSplit(50);
    }

    function test_Split_burn100() public {
        _assertSplit(100);
    }

    function test_BoughtAndBurnedEvent() public {
        _reserve(10e6);
        uint256 out = _quoteOut(10e6);
        uint256 extra = out - 5e18;
        vm.expectEmit(address(batch));
        emit BoughtAndBurned(buyer, 10e6, out, 5e18, 0, extra, 0);
        _buy(10e6);
    }

    // =====================================================================
    // 2. Rally carry-forward
    // =====================================================================

    function test_Rally_allToStaker_shortfallCarries_secondBuyPaysCarriedFirst() public {
        _reserve(10e6); // owed 5e18
        _rally(1_500_000e18); // phUSD now ~6x sUSDS

        (uint256 out1, uint256 toStaker1, uint256 burned1) = _buy(5e6);
        assertLt(out1, 5e18, "rallied: the buy returns less than owed");
        assertEq(burned1, 0);
        assertEq(toStaker1, out1, "everything goes to NFTStaker");
        uint256 carried = 5e18 - out1;
        assertEq(batch.pendingStakerPhUSD(), carried, "shortfall carries forward");

        _crash(2_000_000e18); // phUSD now cheap again
        uint256 stakerBefore = phUSD.balanceOf(nftStaker);
        (uint256 out2, uint256 toStaker2, uint256 burned2) = _buy(5e6);
        assertGt(out2, carried);
        assertEq(batch.pendingStakerPhUSD(), 0, "carried amount paid first");
        assertEq(burned2, out2 - carried, "only the extra beyond the carry is burned (burnPercent 100)");
        assertEq(toStaker2, carried);
        assertEq(phUSD.balanceOf(nftStaker) - stakerBefore, carried);
    }

    // =====================================================================
    // 3. Floors and deadline
    // =====================================================================

    function test_Revert_MinOutAboveAchievable() public {
        _reserve(10e6);
        uint256 out = _quoteOut(10e6);
        vm.prank(buyer);
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        batch.buyAndBurn(10e6, out + 1, block.timestamp);
    }

    function test_Revert_ZeroMinOut() public {
        _reserve(10e6);
        vm.prank(buyer);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__ZeroMinOut.selector);
        batch.buyAndBurn(10e6, 0, block.timestamp);
    }

    function test_Revert_Expired() public {
        _reserve(10e6);
        vm.warp(1000);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__Expired.selector, 999));
        batch.buyAndBurn(10e6, 1, 999);
    }

    // =====================================================================
    // 4. Partial buys
    // =====================================================================

    function test_PartialBuy_leavesRemainderReserved() public {
        _reserve(10e6);
        _buy(4e6);
        assertEq(batch.pendingBuyUSDC(), 6e6);
        assertEq(usdc.balanceOf(address(batch)), 6e6);
        _buy(6e6);
        assertEq(batch.pendingBuyUSDC(), 0);
    }

    function test_Revert_BuyExceedsReserve() public {
        _reserve(10e6);
        _fundPot(50e6); // live pot is NOT reserve and cannot be bought
        vm.startPrank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BuyExceedsReserve.selector, 10e6 + 1, 10e6)
        );
        batch.buyAndBurn(10e6 + 1, 1, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__BuyExceedsReserve.selector, 0, 10e6)
        );
        batch.buyAndBurn(0, 1, block.timestamp);
        vm.stopPrank();
    }

    // =====================================================================
    // 5. Buyer auth and the authVersion kill switch
    // =====================================================================

    function test_Auth_freshDeploy_nobodyAuthorised() public {
        BatchNFTMinterNudgeDiscount fresh = new BatchNFTMinterNudgeDiscount(owner);
        address rando = makeAddr("rando");
        assertEq(fresh.authVersion(), 1);
        assertEq(fresh.buyerAuthVersion(rando), 0);
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, rando)
        );
        fresh.buyAndBurn(1, 1, block.timestamp);
    }

    function test_Auth_unauthorisedCaller() public {
        _reserve(10e6);
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, caller)
        );
        batch.buyAndBurn(10e6, 1, block.timestamp);
    }

    function test_Auth_revoked() public {
        _reserve(10e6);
        vm.prank(owner);
        batch.setAuthorizedBuyer(buyer, false);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, buyer)
        );
        batch.buyAndBurn(10e6, 1, block.timestamp);
    }

    function test_Auth_incrementLocksOutEveryone_reauthWorks_mintingUnaffected() public {
        address buyer2 = makeAddr("buyer2");
        vm.startPrank(owner);
        batch.setAuthorizedBuyer(buyer2, true);
        batch.incrementAuthVersion();
        vm.stopPrank();

        // Minting is unaffected by the kill switch.
        _reserve(10e6);
        assertEq(nft.balanceOf(recipient, IDX), 2);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, buyer)
        );
        batch.buyAndBurn(10e6, 1, block.timestamp);
        vm.prank(buyer2);
        vm.expectRevert(
            abi.encodeWithSelector(BatchNFTMinterNudgeDiscount.BatchMint__UnauthorizedBuyer.selector, buyer2)
        );
        batch.buyAndBurn(10e6, 1, block.timestamp);

        vm.prank(owner);
        batch.setAuthorizedBuyer(buyer, true);
        assertEq(batch.buyerAuthVersion(buyer), 2);
        _buy(10e6);
        assertEq(batch.pendingBuyUSDC(), 0);
    }

    // =====================================================================
    // 6. Bonus phUSD on the contract is untouched (measured delta)
    // =====================================================================

    function test_BonusPhUSDUntouchedByBuy() public {
        _reserve(10e6);
        phUSD.mint(address(batch), 7e18); // bonus pot accrues AFTER the batch
        (uint256 out, uint256 toStaker, uint256 burned) = _buy(10e6);
        assertEq(out, toStaker + burned);
        assertEq(phUSD.balanceOf(address(batch)), 7e18, "bonus phUSD is not swept by the buy");
    }

    // =====================================================================
    // 7. Unset route components
    // =====================================================================

    function _expectNotConfigured() internal {
        vm.prank(buyer);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__BuyNotConfigured.selector);
        batch.buyAndBurn(10e6, 1, block.timestamp);
    }

    function test_Revert_BuyNotConfigured_eachComponent() public {
        _reserve(10e6);
        uint256 snap = vm.snapshotState();

        vm.prank(owner);
        batch.setPSM(ISkyPSM(address(0)));
        _expectNotConfigured();
        vm.revertToState(snap);

        vm.prank(owner);
        batch.setSUSDS(IERC4626(address(0)));
        _expectNotConfigured();
        vm.revertToState(snap);

        vm.prank(owner);
        batch.setSwapRoute(address(0), address(0), address(0));
        _expectNotConfigured();
        vm.revertToState(snap);

        vm.prank(owner);
        batch.setNFTStaker(address(0));
        _expectNotConfigured();
    }

    function test_Revert_SUSDSAssetMismatch() public {
        _reserve(10e6);
        MockERC20 other = new MockERC20("O", "O");
        MockSUSDS wrongVault = new MockSUSDS(IERC20(address(other)));
        vm.prank(owner);
        batch.setSUSDS(IERC4626(address(wrongVault)));
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                BatchNFTMinterNudgeDiscount.BatchMint__SUSDSAssetMismatch.selector, address(other), address(usds)
            )
        );
        batch.buyAndBurn(10e6, 1, block.timestamp);
    }

    function test_Revert_StalePairAfterSUSDSRepoint() public {
        _reserve(10e6);
        MockSUSDS otherVault = new MockSUSDS(IERC20(address(usds)));
        vm.prank(owner);
        batch.setSUSDS(IERC4626(address(otherVault)));
        vm.prank(buyer);
        vm.expectRevert(BatchNFTMinterNudgeDiscount.BatchMint__PairMismatch.selector);
        batch.buyAndBurn(10e6, 1, block.timestamp);
    }

    function test_BuyNotPauseGated() public {
        _reserve(10e6);
        vm.prank(pauser);
        batch.pause();
        _buy(10e6);
        assertEq(batch.pendingBuyUSDC(), 0, "pausing stops reservations, not the drain");
    }

    function test_SetTokenMinterUnaffectsBuy() public {
        _reserve(10e6);
        vm.prank(owner);
        batch.setTokenMinter(ITokenMinterV2(address(0)));
        _buy(10e6);
        assertEq(batch.pendingBuyUSDC(), 0);
    }
}
