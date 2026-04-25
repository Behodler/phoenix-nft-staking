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
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Covers the funding surface of the variable-runway / APY-target
///         model under M-03 sizing. After any funding event (`topUp`,
///         `pullAndRefresh`) the schedule must satisfy:
///             R       = totalStaked * latestPrice * A / SECONDS_PER_YEAR
///             window  = block.timestamp + V / R   (V / R floor-divided)
///             budget  = V - committedDebt
///         where `latestPrice = price / r` (or `price` when `growthBP == 0`),
///         A is the target APY, and V = balance + mintDebt. Also pins the
///         M-03 invariant: stake/unstake re-size R against the new
///         totalStaked.
contract NFTStakerFundingTest is Test {
    using Math for uint256;

    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant INITIAL_ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant APY_PRECISION = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    event Pulled(uint256 inflow, uint256 newBudget);
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event ScheduleRecomputed(uint256 totalNFTValue, uint256 availableValue, uint256 newRate, uint256 newWindowEnd);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        nftMinter.setTotalSupply(INITIAL_ID, 100); // ambient supply

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

        // Mint NFTs and stake some to make S non-zero. Keep totalStaked
        // small (10 of 100 minted) so R != 0 but V dwarfs F.
        nft.mint(alice, INITIAL_ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        nft.mint(bob, INITIAL_ID, 100);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------- helper: closed-form S-based rate ----------

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

    function _expectedRateForCurrentStake() internal view returns (uint256) {
        return _expectedRate(staker.totalStaked(), 100 ether, 1, staker.targetAPY());
    }

    function _stakeFromAlice(uint256 amount) internal {
        vm.prank(alice);
        staker.stake(amount);
    }

    // ---------- pullAndRefresh ----------

    function _assertSolvency(string memory label) internal view {
        uint256 hookDebt = address(staker.dispatcherHook()) == address(0) ? 0 : staker.dispatcherHook().mintDebt();
        assertEq(phUSD.balanceOf(address(staker)) + hookDebt, staker.rewardBudget() + staker.committedDebt(), label);
    }

    function testNonzeroPullMaterialisesInflowAndRecomputes() public {
        _stakeFromAlice(10);
        uint256 inflow = 100_000 ether;
        hook.setPendingMint(inflow);

        uint256 expectedRate = _expectedRateForCurrentStake();

        vm.expectEmit(true, true, true, true, address(staker));
        emit Pulled(inflow, inflow);

        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardBudget(), inflow, "budget must equal V");
        assertEq(staker.rewardRate(), expectedRate, "rate must match closed-form");
        assertEq(staker.windowEnd(), block.timestamp + inflow / expectedRate, "windowEnd must be derived from V/R");
        _assertSolvency("after pullAndRefresh");
    }

    function testZeroPullIsStillARecomputeNoInflowEvent() public {
        _stakeFromAlice(10);
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
        _assertSolvency("after zero-pull pullAndRefresh");
    }

    function testPullWithUnsetHookIsNoInflowStillRecomputes() public {
        _stakeFromAlice(10);
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(0)));

        uint256 expectedRate = _expectedRateForCurrentStake();
        // V = balance (no debt) = 0 -> windowEnd == now
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardBudget(), 0);
        assertEq(staker.rewardRate(), expectedRate);
        assertEq(staker.windowEnd(), block.timestamp);
        _assertSolvency("after unset-hook pullAndRefresh");
    }

    // ---------- topUp ----------

    function testTopUpIncreasesVAndRecomputes() public {
        _stakeFromAlice(10);
        uint256 amount = 100_000 ether;
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);

        uint256 expectedRate = _expectedRateForCurrentStake();

        vm.expectEmit(true, true, true, true, address(staker));
        emit ToppedUp(owner, amount, amount);

        vm.prank(owner);
        staker.topUp(amount);

        assertEq(staker.rewardBudget(), amount, "budget must equal V");
        assertEq(staker.rewardRate(), expectedRate, "rate is APY-driven, independent of topUp size");
        assertEq(staker.windowEnd(), block.timestamp + amount / expectedRate, "windowEnd must be derived from V/R");
        assertEq(phUSD.balanceOf(address(staker)), amount);
        _assertSolvency("after topUp");
    }

    function testTopUpRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }

    // ---------- APY stability across funding events ----------

    function testRateUnchangedAcrossMultiplePullsAndTopUpsWithConstantStakeAndPrice() public {
        _stakeFromAlice(10);
        uint256 expectedRate = _expectedRateForCurrentStake();

        // Sequence: topUp, pull, topUp, pull — all at constant totalStaked.
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
        _stakeFromAlice(10);
        uint256 windowBefore;

        phUSD.mint(owner, 300_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 300_000 ether);

        vm.prank(owner);
        staker.topUp(100_000 ether);
        windowBefore = staker.windowEnd();

        vm.prank(owner);
        staker.topUp(100_000 ether);
        // V doubled, R unchanged -> windowEnd shift ~doubles
        uint256 runwayBefore = windowBefore - block.timestamp;
        uint256 runwayAfter = staker.windowEnd() - block.timestamp;
        // Allow +/- 1 wei of floor-division drift in V/R.
        assertApproxEqAbs(runwayAfter, runwayBefore * 2, 2);
    }

    // ---------- M-03: rate recomputes on stake/unstake ----------

    /// @notice Pins the M-03 fix: under S-based sizing R scales linearly
    ///         with totalStaked, so stake and unstake must re-size R after
    ///         the totalStaked mutation.
    function test_RateRecomputesOnStakeUnstake() public {
        // Top up budget so R can be non-zero.
        phUSD.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.topUp(1_000_000 ether);

        // Step 1: alice stakes 10. Expect R sized for totalStaked=10.
        vm.prank(alice);
        staker.stake(10);
        uint256 rateAfter1 = staker.rewardRate();
        assertEq(rateAfter1, _expectedRate(10, 100 ether, 1, 0.3e18), "R after stake(10) must use post-mutation S");
        assertGt(rateAfter1, 0);

        // Step 2: alice stakes another 10. Expect R doubled (linearly with
        // totalStaked).
        vm.prank(alice);
        staker.stake(10);
        uint256 rateAfter2 = staker.rewardRate();
        assertEq(rateAfter2, _expectedRate(20, 100 ether, 1, 0.3e18), "R after stake(+10) must size for totalStaked=20");
        assertApproxEqAbs(rateAfter2, rateAfter1 * 2, 2, "R must scale linearly with totalStaked");

        // Step 3: alice unstakes 10. Expect R halved back.
        vm.prank(alice);
        staker.unstake(10);
        uint256 rateAfter3 = staker.rewardRate();
        assertEq(
            rateAfter3, _expectedRate(10, 100 ether, 1, 0.3e18), "R after unstake(10) must size for totalStaked=10"
        );
        assertApproxEqAbs(rateAfter3, rateAfter1, 2, "R must return to the pre-stake level");
    }

    /// @notice Stake emits Staked first, then ScheduleRecomputed with the
    ///         post-mutation S as the first event arg. Confirms ordering.
    function test_StakeEmitsScheduleRecomputedAfterStaked() public {
        phUSD.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.topUp(1_000_000 ether);

        vm.recordLogs();
        vm.prank(alice);
        staker.stake(10);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 stakedSig = keccak256("Staked(address,uint256)");
        bytes32 schedSig = keccak256("ScheduleRecomputed(uint256,uint256,uint256,uint256)");
        int256 stakedIdx = -1;
        int256 lastSchedIdx = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == stakedSig) stakedIdx = int256(i);
            if (logs[i].topics.length > 0 && logs[i].topics[0] == schedSig) lastSchedIdx = int256(i);
        }
        assertGe(stakedIdx, 0, "Staked event missing");
        assertGt(lastSchedIdx, stakedIdx, "ScheduleRecomputed must follow Staked (tail recompute)");

        // The last ScheduleRecomputed event should report S = 10 *
        // latestPrice for the post-stake totalStaked.
        uint256 latestPrice = _latestPrice(100 ether, 1);
        uint256 expectedS = 10 * latestPrice;
        (uint256 sFromLog,,,) = abi.decode(logs[uint256(lastSchedIdx)].data, (uint256, uint256, uint256, uint256));
        assertEq(sFromLog, expectedS, "post-stake ScheduleRecomputed must report new S");
    }

    /// @notice Unstake emits Unstaked first, then ScheduleRecomputed with
    ///         the post-mutation S.
    function test_UnstakeEmitsScheduleRecomputedAfterUnstaked() public {
        phUSD.mint(owner, 1_000_000 ether);
        vm.prank(owner);
        phUSD.approve(address(staker), 1_000_000 ether);
        vm.prank(owner);
        staker.topUp(1_000_000 ether);

        vm.prank(alice);
        staker.stake(20);

        vm.recordLogs();
        vm.prank(alice);
        staker.unstake(15);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 unstakedSig = keccak256("Unstaked(address,uint256)");
        bytes32 schedSig = keccak256("ScheduleRecomputed(uint256,uint256,uint256,uint256)");
        int256 unstakedIdx = -1;
        int256 lastSchedIdx = -1;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == unstakedSig) unstakedIdx = int256(i);
            if (logs[i].topics.length > 0 && logs[i].topics[0] == schedSig) lastSchedIdx = int256(i);
        }
        assertGe(unstakedIdx, 0, "Unstaked event missing");
        assertGt(lastSchedIdx, unstakedIdx, "ScheduleRecomputed must follow Unstaked (tail recompute)");

        uint256 latestPrice = _latestPrice(100 ether, 1);
        uint256 expectedS = 5 * latestPrice; // 20 - 15 = 5 staked
        (uint256 sFromLog,,,) = abi.decode(logs[uint256(lastSchedIdx)].data, (uint256, uint256, uint256, uint256));
        assertEq(sFromLog, expectedS, "post-unstake ScheduleRecomputed must report new S");
    }
}
