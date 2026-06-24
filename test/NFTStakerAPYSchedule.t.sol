// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Spec for the variable-runway / APY-target model under M-03
///         sizing: `R = totalStaked * latestPrice * targetAPY /
///         SECONDS_PER_YEAR`. Covers `setTargetAPY` permission & bounds,
///         `_recomputeSchedule` math for empty-pool / N=1-staked / growthBP=0
///         / targetAPY=0 cases, trigger coverage across all recompute sites,
///         cross-submodule sensitivity to price/growth changes, and
///         APY-decrease settlement. The aggregate-N notional `T` of the
///         pre-M-03 model is gone — sizing reads `totalStaked` directly.
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
    // helpers — closed-form S-based rate
    // -------------------------------------------------------------------

    function _latestPrice(uint256 priceNext, uint256 growthBP) internal pure returns (uint256) {
        if (priceNext == 0) return 0;
        if (growthBP == 0) return priceNext;
        uint256 r = APY_PRECISION + growthBP * 1e14;
        return Math.mulDiv(priceNext, APY_PRECISION, r);
    }

    function _expectedRate(uint256 totalStaked_, uint256 priceNext, uint256 growthBP, uint256 A)
        internal
        pure
        returns (uint256)
    {
        uint256 latestPrice = _latestPrice(priceNext, growthBP);
        uint256 S = (totalStaked_ == 0 || latestPrice == 0) ? 0 : totalStaked_ * latestPrice;
        uint256 F = Math.mulDiv(S, A, APY_PRECISION);
        return (F == 0) ? 0 : F / SECONDS_PER_YEAR;
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
        // Seed: stake, warp at old APY 30%, then drop APY to 10%. Alice's
        // pending must reflect the old-rate 30% accrual for the pre-setter
        // window.
        nftMinter.setTotalSupply(ID, 1000);
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false); // no growth -> latestPrice = price
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

        // Pending reward should be exactly the old-rate accrual for the
        // 3600s window (the setter ran with no further time elapsed).
        assertEq(staker.pendingReward(alice), expectedAccrual, "old-rate accrual must be settled before APY drop");

        // And the rate must now reflect the new APY (lower).
        uint256 newRate = staker.rewardRate();
        assertLt(newRate, oldRate);
    }

    // -------------------------------------------------------------------
    // _recomputeSchedule math — edge cases
    // -------------------------------------------------------------------

    function testRecomputeWhenTotalStakedIsZeroZeroesRate() public {
        // No stakers. S = 0, R = 0, windowEnd = now. (Independent of N now —
        // S is sized by totalStaked, not by `nftMinter.totalSupply`.)
        nftMinter.setTotalSupply(ID, 100);
        phUSD.mint(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        assertEq(staker.totalStaked(), 0);
        assertEq(staker.rewardRate(), 0, "R must be 0 when totalStaked=0");
        assertEq(staker.windowEnd(), block.timestamp, "windowEnd must equal now when totalStaked=0");
    }

    function testRecomputeWhenSingleNFTStakedREqualsLatestPriceAPY() public {
        // totalStaked=1, price (next)=100e18, growthBP=1 -> r = 1.0001e18
        // latestPrice = price/r = 100e18 * 1e18 / 1.0001e18
        // S = 1 * latestPrice = latestPrice
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(ID, 1);

        phUSD.mint(address(staker), 1_000_000 ether); // available V

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        // Mint 1 to alice and stake.
        nft.mint(alice, ID, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(1);

        uint256 expectedRate = _expectedRate(1, 100 ether, 1, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "R must match S-based closed-form for totalStaked=1");
    }

    function testRecomputeWhenGrowthBPIsZeroUsesUniformPrice() public {
        // growthBP=0 -> latestPrice = price. S = totalStaked * price.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 5);
        phUSD.mint(address(staker), 1_000_000 ether);

        nft.mint(alice, ID, 5);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(5);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 expectedRate = _expectedRate(5, 100 ether, 0, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "uniform-price S formula failed");
    }

    function testRecomputeWhenTargetAPYIsZeroZeroesRate() public {
        nftMinter.setTotalSupply(ID, 100);
        phUSD.mint(address(staker), 1_000_000 ether);

        nft.mint(alice, ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(100);

        vm.prank(owner);
        staker.setTargetAPY(0);

        assertEq(staker.rewardRate(), 0, "R must be 0 when APY=0");
    }

    function testRecomputeMultiStakeExactValues() public {
        // totalStaked=3, price=100e18, growthBP=1 -> r=1.0001e18.
        // S = 3 * latestPrice. R = S * 0.3e18 / SECONDS_PER_YEAR.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(ID, 3);
        phUSD.mint(address(staker), 1_000_000 ether);

        nft.mint(alice, ID, 3);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(3);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        uint256 expectedRate = _expectedRate(3, 100 ether, 1, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "R must match S-based closed-form for totalStaked=3");
    }

    function testRecomputeLargeStakeMatchesClosedForm() public {
        // totalStaked=1000, growthBP=1, APY=30%. No more rpow involvement;
        // sizing is just totalStaked * latestPrice.
        uint256 staked = 1000;
        uint256 growthBP = 1;
        uint256 priceNext = 100 ether;
        uint256 A = 0.3e18;

        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);
        nftMinter.setTotalSupply(ID, staked);
        phUSD.mint(address(staker), 1_000_000_000 ether);

        nft.mint(alice, ID, staked);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(alice);
        staker.stake(staked);

        vm.prank(owner);
        staker.setTargetAPY(A);

        uint256 expectedRate = _expectedRate(staked, priceNext, growthBP, A);
        assertEq(staker.rewardRate(), expectedRate, "R must match S-based closed-form for totalStaked=1000");
    }

    // -------------------------------------------------------------------
    // Trigger sites — all fire ScheduleRecomputed + update rate/window/budget
    // -------------------------------------------------------------------

    function _seedSchedule() internal {
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(ID, 100);
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
        vm.prank(alice);
        staker.stake(100);
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
        // Mint additional NFTs to alice for further stake.
        nft.mint(alice, ID, 5);
        nftMinter.setTotalSupply(ID, 105);

        uint256 rateBefore = staker.rewardRate();
        assertGt(rateBefore, 0);
        vm.prank(alice);
        staker.stake(5);
        // Rate must scale with totalStaked: 100 -> 105, so R should grow
        // 105/100. Allow 1 wei floor-division drift.
        uint256 expectedRate = _expectedRate(105, 100 ether, 1, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "stake must re-size R against new totalStaked");
        assertGt(staker.rewardRate(), rateBefore, "stake increased totalStaked, rate must grow");
    }

    function testTriggerUnstakeRecomputes() public {
        _seedSchedule();
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.unstake(50);
        // totalStaked dropped from 100 to 50, R should halve.
        uint256 expectedRate = _expectedRate(50, 100 ether, 1, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "unstake must re-size R against new totalStaked");
    }

    function testTriggerClaimRecomputes() public {
        _seedSchedule();
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.claim();
        // totalStaked unchanged on claim — R unchanged.
        uint256 expectedRate = _expectedRate(100, 100 ether, 1, 0.3e18);
        assertEq(staker.rewardRate(), expectedRate, "claim leaves R invariant at constant totalStaked");
    }

    function testTriggerTopUpRecomputes() public {
        _seedSchedule();
        uint256 rateBefore = staker.rewardRate();
        phUSD.mint(owner, 500_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 500_000 ether);
        vm.prank(owner);
        staker.topUp(500_000 ether);
        // totalStaked / price / APY unchanged -> rate unchanged.
        assertEq(staker.rewardRate(), rateBefore, "topUp must not move rate at constant totalStaked/price/APY");
        // windowEnd should extend because V grew
        assertGt(staker.windowEnd(), block.timestamp, "windowEnd must be in the future after topUp");
    }

    function testTriggerPullAndRefreshRecomputes() public {
        _seedSchedule();
        hook.setPendingMint(100 ether);
        vm.prank(owner);
        staker.pullAndRefresh();
        // Rate unchanged — V grew but totalStaked/price/APY unchanged.
        assertGt(staker.rewardRate(), 0);
    }

    function testTriggerSetDispatcherIndexRecomputesAndRequiresEmptyPool() public {
        _seedSchedule();

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setDispatcherIndex(2);

        // Unstake fully and try again
        vm.prank(alice);
        staker.unstake(100);
        nftMinter.setConfig(2, address(0xBEE2), 200 ether, 1, false);
        vm.prank(owner);
        staker.setDispatcherIndex(2);
        assertEq(staker.dispatcherIndex(), 2);
    }

    function testTriggerSetNFTMinterRecomputesAndRequiresEmptyPool() public {
        _seedSchedule();

        MockNFTMinter other = new MockNFTMinter();
        other.setTotalSupply(ID, 1);
        other.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setNFTMinter(INFTSupply(address(other)));

        vm.prank(alice);
        staker.unstake(100);
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
        // S doubles -> F doubles -> R doubles (floor division induced loss < 1)
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

    // -------------------------------------------------------------------
    // Geometric-growth case — earliest minter earns above target
    // -------------------------------------------------------------------

    function testGeometricGrowthLatestPriceMatchesPriceOverR() public {
        // growthBP > 0 -> latestPrice = price.mulDiv(1e18, r). Verified via
        // R inversion: from observed rewardRate, recover the latestPrice the
        // contract used and assert it equals price/r exactly.
        uint256 priceNext = 200 ether;
        uint256 growthBP = 50; // 0.5%
        uint256 A = 0.4e18;
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);
        nftMinter.setTotalSupply(ID, 7);

        nft.mint(alice, ID, 7);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        phUSD.mint(address(staker), 1_000_000 ether);
        vm.prank(alice);
        staker.stake(7);

        vm.prank(owner);
        staker.setTargetAPY(A);

        uint256 expectedRate = _expectedRate(7, priceNext, growthBP, A);
        assertEq(staker.rewardRate(), expectedRate, "geometric-growth rate must use latestPrice = price/r");
    }
}
