// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerPriceScaled} from "../src/NFTStakerPriceScaled.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Focused TDD suite for `NFTStakerPriceScaled` — the decimal-
///         normalizing standalone copy of `NFTStaker`. Proves: the zero-scale
///         constructor guard, immutable wiring, the `priceScale` multiply that
///         rescues a 6dp-priced dispatcher from rate-floor-to-zero, anti-drift
///         vs the original `NFTStaker` at `priceScale == 1`, and an end-to-end
///         accrual/claim cycle at a non-1 scale. The rate helpers mirror
///         `NFTStakerAPYSchedule.t.sol::_expectedRate` /
///         `NFTStakerFuzz.t.sol::_closedFormRate`, folding the `priceScale`
///         multiply into `latestPrice` exactly as the contract does.
contract NFTStakerPriceScaledTest is Test {
    using Math for uint256;

    NFTStakerPriceScaled internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant APY_PRECISION = 1e18;

    // Ratchet: 18dp phUSD reward, 6dp USDC prime -> 10 ** (18 - 6) = 1e12.
    uint256 internal constant RATCHET_PRICE_SCALE = 1e12;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Default config: price 100e6 (6dp USDC NEXT mint price), growthBP=0.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);

        staker = new NFTStakerPriceScaled(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            RATCHET_PRICE_SCALE
        );
    }

    // -------------------------------------------------------------------
    // helpers — closed-form S-based rate, with the priceScale fold-in
    // -------------------------------------------------------------------

    function _latestPrice(uint256 priceNext, uint256 growthBP, uint256 priceScale) internal pure returns (uint256) {
        uint256 latestPrice;
        if (priceNext == 0) {
            latestPrice = 0;
        } else if (growthBP == 0) {
            latestPrice = priceNext;
        } else {
            uint256 r = APY_PRECISION + growthBP * 1e14;
            latestPrice = Math.mulDiv(priceNext, APY_PRECISION, r);
        }
        // Mirror the contract: fold the priceScale multiply into latestPrice.
        return latestPrice * priceScale;
    }

    function _expectedRate(uint256 totalStaked_, uint256 priceNext, uint256 growthBP, uint256 A, uint256 priceScale)
        internal
        pure
        returns (uint256)
    {
        uint256 latestPrice = _latestPrice(priceNext, growthBP, priceScale);
        uint256 S = (totalStaked_ == 0 || latestPrice == 0) ? 0 : totalStaked_ * latestPrice;
        uint256 F = Math.mulDiv(S, A, APY_PRECISION);
        return (F == 0) ? 0 : F / SECONDS_PER_YEAR;
    }

    function _deployScaled(uint256 priceScale) internal returns (NFTStakerPriceScaled) {
        return new NFTStakerPriceScaled(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            priceScale
        );
    }

    // -------------------------------------------------------------------
    // Constructor — zero-scale guard + wiring
    // -------------------------------------------------------------------

    function testConstructorRejectsZeroPriceScale() public {
        vm.expectRevert(bytes("NFTStaker: zero price scale"));
        new NFTStakerPriceScaled(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            0
        );
    }

    function testConstructorWiresPriceScale() public {
        NFTStakerPriceScaled s = _deployScaled(RATCHET_PRICE_SCALE);
        assertEq(s.priceScale(), RATCHET_PRICE_SCALE, "priceScale not wired");
        assertEq(address(s.stakedToken()), address(nft), "stakedToken not wired");
        assertEq(s.stakedId(), ID, "stakedId not wired");
        assertEq(address(s.rewardToken()), address(phUSD), "rewardToken not wired");
        assertEq(address(s.nftMinter()), address(nftMinter), "nftMinter not wired");
        assertEq(s.dispatcherIndex(), DISPATCHER_INDEX, "dispatcherIndex not wired");
        assertEq(s.owner(), owner, "owner not wired");
        assertEq(s.targetAPY(), 0, "targetAPY default not zero");
    }

    // -------------------------------------------------------------------
    // Regression — priceScale rescues a 6dp price from rate-floor-to-zero
    // -------------------------------------------------------------------

    function testPriceScaleNormalizes6dpPrice() public {
        // priceScale=1e12, config price 100e6 (6dp), growthBP=0, totalStaked=1,
        // targetAPY=0.45e18.
        //   latestPrice = 100e6 * 1e12 = 1e20  (= 100 phUSD, correct)
        //   S = 1 * 1e20 = 1e20
        //   F = 1e20 * 0.45e18 / 1e18 = 0.45e20
        //   rewardRate = F / 365 days  (visibly non-zero)
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 1);
        phUSD.mint(address(staker), 1_000_000 ether);

        nft.mint(alice, ID, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(1);

        vm.prank(owner);
        staker.setTargetAPY(0.45e18);

        uint256 expected = (1e20 * 0.45e18 / 1e18) / SECONDS_PER_YEAR;
        assertGt(expected, 0, "checked-form expected rate must be non-zero");
        assertEq(staker.rewardRate(), expected, "rewardRate must match the scaled closed form");
        assertEq(staker.rewardRate(), _expectedRate(1, 100e6, 0, 0.45e18, RATCHET_PRICE_SCALE), "helper mismatch");
    }

    // -------------------------------------------------------------------
    // Anti-drift — priceScale=1 must match the original NFTStaker exactly
    // -------------------------------------------------------------------

    function testPriceScaleOneMatchesOriginalNFTStaker() public {
        // Identical config / stake / APY against both contracts; with
        // priceScale==1 the scaled copy must be behaviorally identical.
        uint256 priceNext = 100 ether; // 18dp, like the pooler
        uint256 growthBP = 1;
        uint256 A = 0.3e18;
        uint256 staked = 7;

        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);
        nftMinter.setTotalSupply(ID, staked);

        NFTStakerPriceScaled scaled = _deployScaled(1);
        NFTStaker original = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        // Fund both equally and run the identical sequence.
        phUSD.mint(address(scaled), 1_000_000 ether);
        phUSD.mint(address(original), 1_000_000 ether);

        nft.mint(alice, ID, staked * 2);
        vm.prank(alice);
        nft.setApprovalForAll(address(scaled), true);
        vm.prank(alice);
        nft.setApprovalForAll(address(original), true);

        vm.prank(alice);
        scaled.stake(staked);
        vm.prank(alice);
        original.stake(staked);

        vm.prank(owner);
        scaled.setTargetAPY(A);
        vm.prank(owner);
        original.setTargetAPY(A);

        assertEq(scaled.rewardRate(), original.rewardRate(), "rewardRate drifted from original NFTStaker");
        assertEq(scaled.rewardBudget(), original.rewardBudget(), "rewardBudget drifted from original NFTStaker");
        assertEq(scaled.windowEnd(), original.windowEnd(), "windowEnd drifted from original NFTStaker");
    }

    // -------------------------------------------------------------------
    // End-to-end accrual/claim at a non-1 priceScale
    // -------------------------------------------------------------------

    function testAccrualClaimMatchesScaledRate() public {
        // Full stake -> warp -> claim cycle on the 6dp-priced ratchet config
        // with priceScale=1e12; accrued phUSD must equal the scaled rate * dt.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 10);
        phUSD.mint(address(staker), 10_000_000 ether);

        nft.mint(alice, ID, 10);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(10);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 rate = staker.rewardRate();
        assertGt(rate, 0, "rate must be non-zero under the scaled config");
        assertEq(rate, _expectedRate(10, 100e6, 0, 0.3e18, RATCHET_PRICE_SCALE), "rate must match scaled closed form");

        assertEq(staker.pendingReward(alice), 0, "no accrual before warp");

        vm.warp(block.timestamp + 1 days);
        uint256 expectedAccrual = rate * 1 days;
        assertEq(staker.pendingReward(alice), expectedAccrual, "pending must equal scaled rate * elapsed");

        uint256 balBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice) - balBefore, expectedAccrual, "claim must transfer scaled accrual");
        assertEq(staker.pendingReward(alice), 0, "pending zeroed after claim");
    }
}
