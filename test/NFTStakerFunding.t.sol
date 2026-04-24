// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Covers the funding surface of the variable-runway / APY-target
///         model. After any funding event (`topUp`, `pullAndRefresh`) the
///         schedule must satisfy:
///             R       = T * A / SECONDS_PER_YEAR
///             window  = block.timestamp + V / R   (V / R floor-divided)
///             budget  = V
///         where T is the closed-form aggregate NFT value, A is the target
///         APY, and V = balance + mintDebt.
contract NFTStakerFundingTest is Test {
    using Math for uint256;

    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    uint256 internal constant INITIAL_ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant APY_PRECISION = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    event Pulled(uint256 inflow, uint256 newBudget);
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(INITIAL_ID, 100); // non-trivial N so T > 0

        staker = new NFTStaker(
            IERC1155(address(nft)),
            INITIAL_ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);
    }

    // ---------- helper: closed-form T ----------

    function _computeT(uint256 price, uint256 growthBP, uint256 N) internal pure returns (uint256) {
        if (N == 0 || price == 0) return 0;
        if (growthBP == 0) return price * N;
        uint256 r = APY_PRECISION + growthBP * 1e14;
        uint256 latestPrice = Math.mulDiv(price, APY_PRECISION, r);
        if (N == 1) return latestPrice;
        uint256 rPowN = FixedPointMathLib.rpow(r, N, APY_PRECISION);
        uint256 rPowNm1 = FixedPointMathLib.rpow(r, N - 1, APY_PRECISION);
        uint256 rMinusOne = r - APY_PRECISION;
        uint256 num = Math.mulDiv(latestPrice, rPowN - APY_PRECISION, APY_PRECISION);
        uint256 den = Math.mulDiv(rPowNm1, rMinusOne, APY_PRECISION);
        return Math.mulDiv(num, APY_PRECISION, den);
    }

    function _expectedRate() internal view returns (uint256) {
        uint256 T = _computeT(100 ether, 1, 100);
        uint256 F = Math.mulDiv(T, staker.targetAPY(), APY_PRECISION);
        return F / SECONDS_PER_YEAR;
    }

    // ---------- pullAndRefresh ----------

    function testNonzeroPullMaterialisesInflowAndRecomputes() public {
        uint256 inflow = 100_000 ether;
        hook.setPendingMint(inflow);

        uint256 expectedRate = _expectedRate();

        vm.expectEmit(true, true, true, true, address(staker));
        emit Pulled(inflow, inflow);

        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardBudget(), inflow, "budget must equal V");
        assertEq(staker.rewardRate(), expectedRate, "rate must match closed-form");
        assertEq(staker.windowEnd(), block.timestamp + inflow / expectedRate, "windowEnd must be derived from V/R");
    }

    function testZeroPullIsStillARecomputeNoInflowEvent() public {
        // Establish a baseline budget via a topUp.
        uint256 amount = 50_000 ether;
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);
        vm.prank(owner);
        staker.topUp(amount);

        uint256 budgetBefore = staker.rewardBudget();
        uint256 rateBefore = staker.rewardRate();

        hook.setPendingMint(0);

        vm.recordLogs();
        vm.prank(owner);
        staker.pullAndRefresh();

        bytes32 pulledSig = keccak256("Pulled(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != pulledSig, "Pulled emitted on zero inflow");
            }
        }

        // Recompute still fires; V is unchanged so the rate is unchanged.
        assertEq(staker.rewardBudget(), budgetBefore);
        assertEq(staker.rewardRate(), rateBefore);
    }

    function testPullWithUnsetHookIsNoInflowStillRecomputes() public {
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(0)));

        uint256 expectedRate = _expectedRate();
        // V = balance (no debt) = 0 -> windowEnd == now
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardBudget(), 0);
        assertEq(staker.rewardRate(), expectedRate);
        assertEq(staker.windowEnd(), block.timestamp);
    }

    // ---------- topUp ----------

    function testTopUpIncreasesVAndRecomputes() public {
        uint256 amount = 100_000 ether;
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);

        uint256 expectedRate = _expectedRate();

        vm.expectEmit(true, true, true, true, address(staker));
        emit ToppedUp(owner, amount, amount);

        vm.prank(owner);
        staker.topUp(amount);

        assertEq(staker.rewardBudget(), amount, "budget must equal V");
        assertEq(staker.rewardRate(), expectedRate, "rate is APY-driven, independent of topUp size");
        assertEq(staker.windowEnd(), block.timestamp + amount / expectedRate, "windowEnd must be derived from V/R");
        assertEq(phUSD.balanceOf(address(staker)), amount);
    }

    function testTopUpRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }

    // ---------- APY stability across funding events ----------

    function testRateUnchangedAcrossMultiplePullsAndTopUpsWithConstantNAndPrice() public {
        uint256 expectedRate = _expectedRate();

        // Sequence: topUp, pull, topUp, pull — all at constant T.
        phUSD.mint(owner, 200_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 200_000 ether);

        vm.prank(owner);
        staker.topUp(50_000 ether);
        assertEq(staker.rewardRate(), expectedRate, "rate drift after first topUp");

        hook.setPendingMint(30_000 ether);
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardRate(), expectedRate, "rate drift after first pull");

        vm.prank(owner);
        staker.topUp(50_000 ether);
        assertEq(staker.rewardRate(), expectedRate, "rate drift after second topUp");

        hook.setPendingMint(30_000 ether);
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardRate(), expectedRate, "rate drift after second pull");
    }

    // ---------- runway is derived ----------

    function testRunwayGrowsLinearlyWithV() public {
        uint256 rateBefore;
        uint256 windowBefore;

        phUSD.mint(owner, 300_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 300_000 ether);

        vm.prank(owner);
        staker.topUp(100_000 ether);
        rateBefore = staker.rewardRate();
        windowBefore = staker.windowEnd();

        vm.prank(owner);
        staker.topUp(100_000 ether);
        // V doubled, R unchanged -> windowEnd shift ~doubles
        uint256 runwayBefore = windowBefore - block.timestamp;
        uint256 runwayAfter = staker.windowEnd() - block.timestamp;
        // Allow +/- 1 wei of floor-division drift in V/R.
        assertApproxEqAbs(runwayAfter, runwayBefore * 2, 2);
    }
}
