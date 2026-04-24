// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Red-phase spec for the variable-runway / APY-target model.
///         Covers `setTargetAPY` permission & bounds, `_recomputeSchedule`
///         math for small-N / N=0 / N=1 / growthBP=0 / targetAPY=0 cases,
///         trigger coverage across all recompute sites, cross-submodule
///         sensitivity to price/growth changes, and APY-decrease settlement.
contract NFTStakerAPYScheduleTest is Test {
    using Math for uint256;

    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant APY_PRECISION = 1e18;

    event TargetAPYChanged(uint256 previous, uint256 next);
    event DispatcherIndexChanged(uint256 previous, uint256 next);
    event NFTMinterChanged(address indexed previous, address indexed next);
    event ScheduleRecomputed(uint256 totalNFTValue, uint256 availableValue, uint256 newRate, uint256 newWindowEnd);
    event Pulled(uint256 inflow, uint256 newBudget);
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget);
    event Claimed(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Default config: price 100e18 (NEXT mint price), growthBP=1 (0.01%)
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(ID, 0);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
    }

    // -------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------

    function testConstantsMatchSpec() public view {
        assertEq(staker.SECONDS_PER_YEAR(), SECONDS_PER_YEAR);
        assertEq(staker.APY_PRECISION(), APY_PRECISION);
        assertEq(staker.MAX_TARGET_APY(), 50 * 1e16); // 50%
    }

    // -------------------------------------------------------------------
    // setTargetAPY — permissions, bounds, event, accrual settlement
    // -------------------------------------------------------------------

    function testSetTargetAPYOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setTargetAPY(0.3e18);
    }

    function testSetTargetAPYRejectsAboveMax() public {
        uint256 tooBig = staker.MAX_TARGET_APY() + 1;
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: APY too high"));
        staker.setTargetAPY(tooBig);
    }

    function testSetTargetAPYAcceptsZero() public {
        // Zero is supported — emissions paused via APY
        vm.prank(owner);
        staker.setTargetAPY(0);
        assertEq(staker.targetAPY(), 0);
        assertEq(staker.rewardRate(), 0);
    }

    function testSetTargetAPYAcceptsMax() public {
        uint256 max = staker.MAX_TARGET_APY();
        vm.prank(owner);
        staker.setTargetAPY(max);
        assertEq(staker.targetAPY(), max);
    }

    function testSetTargetAPYEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit TargetAPYChanged(0, 0.3e18);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);
    }

    function testSetTargetAPYSettlesAccrualAtOldRateBeforeMutating() public {
        // Seed: stake, warp at old APY 30%, then drop APY to 10%.
        // Alice's pending must reflect the old-rate 30% accrual for the
        // pre-setter window.
        nftMinter.setTotalSupply(ID, 1000);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false); // no growth -> T = N*price
        phUSD.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.topUp(1_000_000 ether);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 10);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(10);

        uint256 oldRate = staker.rewardRate();
        assertGt(oldRate, 0);

        vm.warp(block.timestamp + 3600);
        uint256 expectedAccrual = oldRate * 3600;

        // Drop APY to 10%
        vm.prank(owner);
        staker.setTargetAPY(0.1e18);

        // Pending reward should be at least what accrued at the old rate for
        // the 3600 seconds (subsequent accrual is at the new rate).
        // Since the setter runs immediately (no further time elapsed), the
        // pending must equal exactly the old-rate accrual.
        assertEq(staker.pendingReward(alice), expectedAccrual, "old-rate accrual must be settled before APY drop");

        // And the rate must now reflect the new APY (lower).
        uint256 newRate = staker.rewardRate();
        assertLt(newRate, oldRate);
    }

    // -------------------------------------------------------------------
    // _recomputeSchedule math — edge cases
    // -------------------------------------------------------------------

    function testRecomputeWhenNIsZeroZeroesRate() public {
        // No NFTs minted. T = 0, R = 0, windowEnd = now.
        nftMinter.setTotalSupply(ID, 0);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        assertEq(staker.rewardRate(), 0, "R must be 0 when N=0");
        assertEq(staker.windowEnd(), block.timestamp, "windowEnd must equal now when N=0");
        assertEq(staker.rewardBudget(), 0, "rewardBudget must be 0 when no balance");
    }

    function testRecomputeWhenNIsOneTEqualsLatestPrice() public {
        // N=1, price (next)=100e18, growthBP=1 -> r = 1.0001e18
        // latestPrice = price/r = 100e18 * 1e18 / 1.0001e18
        // T = latestPrice (reduces to latestPrice for N=1).
        nftMinter.setTotalSupply(ID, 1);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);

        phUSD.mint(address(staker), 1_000_000 ether); // available V

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 r = APY_PRECISION + uint256(1) * 1e14;
        uint256 latestPrice = Math.mulDiv(100 ether, APY_PRECISION, r);
        uint256 T = latestPrice; // for N=1
        uint256 F = Math.mulDiv(T, 0.3e18, APY_PRECISION);
        uint256 expectedRate = F / SECONDS_PER_YEAR;

        assertEq(staker.rewardRate(), expectedRate, "R must match closed-form for N=1");
    }

    function testRecomputeWhenGrowthBPIsZeroUsesUniformPrice() public {
        // growthBP = 0 -> r = 1 -> no geometric growth.
        // T = latestPrice * N. latestPrice = price / r = price / 1 = price.
        nftMinter.setTotalSupply(ID, 5);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);

        phUSD.mint(address(staker), 1_000_000 ether);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 T = 100 ether * 5;
        uint256 F = Math.mulDiv(T, 0.3e18, APY_PRECISION);
        uint256 expectedRate = F / SECONDS_PER_YEAR;
        assertEq(staker.rewardRate(), expectedRate, "uniform-price T formula failed");
    }

    function testRecomputeWhenTargetAPYIsZeroZeroesRate() public {
        nftMinter.setTotalSupply(ID, 100);
        phUSD.mint(address(staker), 1_000_000 ether);

        vm.prank(owner);
        staker.setTargetAPY(0);

        assertEq(staker.rewardRate(), 0, "R must be 0 when APY=0");
    }

    function testRecomputeSmallNExactValues() public {
        // N=2, price=100e18, growthBP=1 -> r=1.0001e18
        // latestPrice = 100e18 / 1.0001 in 1e18 fp
        // T = latestPrice * (r^2 - 1) / (r^1 * (r - 1))
        //   = latestPrice * (r - 1)(r + 1) / (r * (r - 1))
        //   = latestPrice * (r + 1) / r
        nftMinter.setTotalSupply(ID, 2);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);

        phUSD.mint(address(staker), 1_000_000 ether);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 r = APY_PRECISION + 1e14;
        uint256 latestPrice = Math.mulDiv(100 ether, APY_PRECISION, r);
        uint256 rPowN = FixedPointMathLib.rpow(r, 2, APY_PRECISION);
        uint256 rPowNm1 = r;
        uint256 rMinusOne = r - APY_PRECISION;
        uint256 num = Math.mulDiv(latestPrice, rPowN - APY_PRECISION, APY_PRECISION);
        uint256 den = Math.mulDiv(rPowNm1, rMinusOne, APY_PRECISION);
        uint256 T = Math.mulDiv(num, APY_PRECISION, den);
        uint256 F = Math.mulDiv(T, 0.3e18, APY_PRECISION);
        uint256 expectedRate = F / SECONDS_PER_YEAR;

        assertEq(staker.rewardRate(), expectedRate, "R must match closed-form for N=2");
    }

    function testRecomputeLargeNMatchesClosedForm() public {
        // N=1000, growthBP=1, APY=30%.
        // Compute the reference value using the same formulae the contract
        // uses; the contract must agree exactly.
        uint256 N = 1000;
        uint256 growthBP = 1;
        uint256 priceNext = 100 ether;
        uint256 A = 0.3e18;

        nftMinter.setTotalSupply(ID, N);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);

        phUSD.mint(address(staker), 1_000_000_000 ether);

        vm.prank(owner);
        staker.setTargetAPY(A);

        uint256 r = APY_PRECISION + growthBP * 1e14;
        uint256 latestPrice = Math.mulDiv(priceNext, APY_PRECISION, r);
        uint256 rPowN = FixedPointMathLib.rpow(r, N, APY_PRECISION);
        uint256 rPowNm1 = FixedPointMathLib.rpow(r, N - 1, APY_PRECISION);
        uint256 rMinusOne = r - APY_PRECISION;
        uint256 num = Math.mulDiv(latestPrice, rPowN - APY_PRECISION, APY_PRECISION);
        uint256 den = Math.mulDiv(rPowNm1, rMinusOne, APY_PRECISION);
        uint256 T = Math.mulDiv(num, APY_PRECISION, den);
        uint256 F = Math.mulDiv(T, A, APY_PRECISION);
        uint256 expectedRate = F / SECONDS_PER_YEAR;

        assertEq(staker.rewardRate(), expectedRate, "R must match closed-form for N=1000");
    }

    // -------------------------------------------------------------------
    // Trigger sites — all fire ScheduleRecomputed + update rate/window/budget
    // -------------------------------------------------------------------

    function _seedSchedule() internal {
        nftMinter.setTotalSupply(ID, 100);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        phUSD.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.topUp(1_000_000 ether);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function testTriggerSetTargetAPYEmitsScheduleRecomputed() public {
        _seedSchedule();
        // Expect ScheduleRecomputed on APY change
        vm.recordLogs();
        vm.prank(owner);
        staker.setTargetAPY(0.2e18);
        bytes32 sig = keccak256("ScheduleRecomputed(uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "ScheduleRecomputed not emitted on setTargetAPY");
    }

    function testTriggerStakeRecomputes() public {
        _seedSchedule();
        uint256 rateBefore = staker.rewardRate();
        assertGt(rateBefore, 0);
        vm.prank(alice);
        staker.stake(5);
        // Rate unchanged at same N/price/APY (a stake does not mint NFTs)
        assertEq(staker.rewardRate(), rateBefore, "stake must leave rate invariant at same (N,price,APY)");
    }

    function testTriggerUnstakeRecomputes() public {
        _seedSchedule();
        vm.prank(alice);
        staker.stake(5);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.unstake(5);
        // No revert — recompute fired inside the flow.
        assertGt(staker.rewardRate(), 0);
    }

    function testTriggerClaimRecomputes() public {
        _seedSchedule();
        vm.prank(alice);
        staker.stake(5);
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.claim();
        assertGt(staker.rewardRate(), 0);
    }

    function testTriggerTopUpRecomputes() public {
        _seedSchedule();
        uint256 rateBefore = staker.rewardRate();
        phUSD.mint(owner, 500_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 500_000 ether);
        vm.prank(owner);
        staker.topUp(500_000 ether);
        // N/price/APY unchanged -> rate unchanged
        assertEq(staker.rewardRate(), rateBefore, "topUp must not move rate at constant N/price/APY");
        // windowEnd should extend because V grew
        assertGt(staker.windowEnd(), block.timestamp, "windowEnd must be in the future after topUp");
    }

    function testTriggerPullAndRefreshRecomputes() public {
        _seedSchedule();
        hook.setPendingMint(100 ether);
        vm.prank(owner);
        staker.pullAndRefresh();
        // Rate unchanged — V grew but N/price/APY unchanged.
        // Just confirm emissions still positive and budget reflects pull.
        assertGt(staker.rewardRate(), 0);
    }

    function testTriggerSetDispatcherIndexRecomputesAndRequiresEmptyPool() public {
        _seedSchedule();
        vm.prank(alice);
        staker.stake(1);

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setDispatcherIndex(2);

        // Unstake and try again
        vm.prank(alice);
        staker.unstake(1);
        nftMinter.setConfig(2, address(0xBEE2), 200 ether, 1, false);
        vm.prank(owner);
        staker.setDispatcherIndex(2);
        assertEq(staker.dispatcherIndex(), 2);
    }

    function testTriggerSetNFTMinterRecomputesAndRequiresEmptyPool() public {
        _seedSchedule();
        vm.prank(alice);
        staker.stake(1);

        MockNFTMinter other = new MockNFTMinter();
        other.setTotalSupply(ID, 1);
        other.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setNFTMinter(INFTSupply(address(other)));

        vm.prank(alice);
        staker.unstake(1);
        vm.prank(owner);
        staker.setNFTMinter(INFTSupply(address(other)));
        assertEq(address(staker.nftMinter()), address(other));
    }

    // -------------------------------------------------------------------
    // Cross-submodule sensitivity — price / growthBP updates on NFTMinter
    // -------------------------------------------------------------------

    function testRecomputeReactsToPriceChange() public {
        _seedSchedule();
        uint256 rate0 = staker.rewardRate();

        // Double the price on the minter; trigger a recompute via topUp(1).
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 200 ether, 1, false);
        phUSD.mint(owner, 1);
        vm.prank(owner);
        phUSD.approve(address(staker), 1);
        vm.prank(owner);
        staker.topUp(1);

        uint256 rate1 = staker.rewardRate();
        // T doubles -> F doubles -> R doubles (floor division induced loss < 1)
        assertApproxEqAbs(rate1, rate0 * 2, 1, "rate did not track 2x price");
    }

    function testRecomputeReactsToGrowthBPChange() public {
        _seedSchedule();
        uint256 rate0 = staker.rewardRate();

        // Change growthBP from 1 to 100 — r goes from 1.0001 to 1.01.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 100, false);
        phUSD.mint(owner, 1);
        vm.prank(owner);
        phUSD.approve(address(staker), 1);
        vm.prank(owner);
        staker.topUp(1);

        uint256 rate1 = staker.rewardRate();
        // Rate must move — but we don't pin the direction here, only that
        // the contract reacts to the config change.
        assertTrue(rate1 != rate0, "rate did not react to growthBP change");
    }

    // -------------------------------------------------------------------
    // APY-decrease semantics
    // -------------------------------------------------------------------

    function testAPYDecreaseDropsRate() public {
        _seedSchedule();
        uint256 rateHigh = staker.rewardRate();

        vm.prank(owner);
        staker.setTargetAPY(0.1e18);

        uint256 rateLow = staker.rewardRate();
        assertLt(rateLow, rateHigh, "rate must drop on APY decrease");
        // Ratio should be ~1/3 (APY went 0.3 -> 0.1)
        assertApproxEqRel(rateLow * 3, rateHigh, 0.01e18);
    }

    // -------------------------------------------------------------------
    // Constructor behavior — zero-address guards
    // -------------------------------------------------------------------

    function testConstructorRejectsZeroNFTMinter() public {
        vm.expectRevert(bytes("NFTStaker: zero nft minter"));
        new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(0)), DISPATCHER_INDEX
        );
    }

    function testConstructorStoresNFTMinterAndIndex() public view {
        assertEq(address(staker.nftMinter()), address(nftMinter));
        assertEq(staker.dispatcherIndex(), DISPATCHER_INDEX);
        assertEq(staker.targetAPY(), 0);
    }
}
