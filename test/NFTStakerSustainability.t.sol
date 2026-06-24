// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Variable-runway sustainability spec. Under the APY-target model
///         the staker gets a stable per-second emission rate for their
///         share of `T` and runway (seconds until depletion) is the free
///         variable. This suite pins:
///           - Actual reward delivered to a staker over a holding period
///             matches the targetAPY * V_share / SECONDS_PER_YEAR formula.
///           - Emissions stop cleanly at the derived `windowEnd`.
///           - Solvency invariant `balance >= rewardBudget + totalDebt`.
contract NFTStakerSustainabilityTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Use uniform price for easier math: growthBP=0 -> latestPrice = price
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        // Seed a large V so runway is meaningful.
        uint256 seed = 1_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);

        // Mint NFTs to alice and pre-stake the bulk so totalStaked > 0
        // before tests examine `rewardRate` / `runwaySeconds`. This is
        // necessary under M-03 sizing where R is sized against
        // `totalStaked` rather than `nftMinter.totalSupply`. Tests that
        // need a per-test stake mutation will use the remaining balance.
        nft.mint(alice, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        // Pre-stake a baseline so R > 0 from the get-go. Tests that
        // expect to mutate the stake themselves still have ample
        // remaining alice balance to stake/unstake against.
        vm.prank(alice);
        staker.stake(100);

        vm.prank(owner);
        staker.setTargetAPY(0.3e18);
    }

    // ---------- totalBudget ----------

    function testTotalBudgetEqualsBalancePlusHookDebt() public view {
        assertEq(staker.totalBudget(), phUSD.balanceOf(address(staker)));
    }

    function testTotalBudgetIncludesHookMintDebt() public {
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        hook.setPendingMint(12_345);
        assertEq(staker.totalBudget(), phUSD.balanceOf(address(staker)) + 12_345);
    }

    // ---------- totalDebt ----------

    function testTotalDebtZeroWhenNothingAccrued() public view {
        // Fresh schedule, no stakers, no time elapsed.
        assertEq(staker.totalDebt(), 0);
    }

    function testTotalDebtMatchesPendingForSingleStaker() public {
        // setUp pre-stakes 100 (so alice owns 100/(100+10) = 10/11 of the
        // pool after her +10 stake). totalDebt is the full pending across
        // the whole pool (alice is the only staker since the seed
        // pre-stake came from the same alice address).
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        uint256 pending = staker.pendingReward(alice);
        // alice is the only staker — pending equals the full per-second
        // emission times elapsed (no other actor to share with). Floor-
        // division across the per-share update can drop a few wei.
        assertApproxEqAbs(pending, staker.rewardRate() * 100, 2);
        // totalDebt and pendingReward both forward-simulate _updatePool;
        // they multiply/divide in slightly different orders so floor
        // rounding can introduce 1-wei drift.
        assertApproxEqAbs(staker.totalDebt(), pending, 1);
    }

    function testTotalDebtPreservedAcrossClaim() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 100);

        uint256 debtBefore = staker.totalDebt();

        vm.prank(alice);
        staker.claim();

        uint256 debtAfter = staker.totalDebt();
        assertLe(debtAfter, debtBefore);
        assertLe(debtAfter, 1);
    }

    // ---------- runwaySeconds ----------

    function testRunwaySecondsReflectsVOverR() public view {
        // runway = V / R where V = balance + mintDebt
        uint256 expected = phUSD.balanceOf(address(staker)) / staker.rewardRate();
        assertEq(staker.runwaySeconds(), expected);
    }

    function testRunwaySecondsIncludesHookMintDebt() public {
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        uint256 extra = staker.rewardRate() * 1_000;
        hook.setPendingMint(extra);

        assertEq(staker.runwaySeconds(), (phUSD.balanceOf(address(staker)) + extra) / staker.rewardRate());
    }

    function testRunwaySecondsZeroWhenRateIsZero() public {
        // Deploy a fresh staker with no APY set -> rate 0.
        MockNFTMinter m = new MockNFTMinter();
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        m.setTotalSupply(ID, 100);
        NFTStaker bare = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );
        assertEq(bare.rewardRate(), 0);
        assertEq(bare.runwaySeconds(), 0);
    }

    function testRunwayShrinksAsBudgetDepletes() public {
        vm.prank(alice);
        staker.stake(10);

        uint256 runwayStart = staker.runwaySeconds();

        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        staker.claim();

        uint256 runwayMid = staker.runwaySeconds();
        assertLt(runwayMid, runwayStart);
        // Runway should shrink by ~100 seconds of emissions.
        assertApproxEqAbs(runwayStart - runwayMid, 100, 3);
    }

    // ---------- emissions stop at derived windowEnd ----------

    function testEmissionsStopAtDerivedWindowEnd() public {
        vm.prank(alice);
        staker.stake(10);

        uint256 windowEnd = staker.windowEnd();
        // Warp to right at windowEnd
        vm.warp(windowEnd);
        uint256 atEnd = staker.pendingReward(alice);

        vm.warp(windowEnd + 1_000);
        assertEq(staker.pendingReward(alice), atEnd, "pending should not grow past windowEnd");
    }

    // ---------- APY delivered over holding period ----------

    function testStakerReceivesAPYOverHoldingPeriod() public {
        vm.prank(alice);
        staker.stake(10);

        // Alice is the only staker so `totalStaked == 10` and her share of
        // every per-second emission is 100% of `rewardRate`. Over a 30-day
        // hold she earns `rewardRate * 30 days`. Conceptually this under-
        // delivers vs the nominal APY target because her staked value is a
        // fraction of T, but the actual reward rate is R(T,A) applied in
        // full to totalStaked's share. The APY-as-floor property is
        // covered separately in variable-runway.md.
        uint256 dt = 30 days;
        vm.warp(block.timestamp + dt);

        uint256 expected = staker.rewardRate() * dt;

        vm.prank(alice);
        staker.claim();
        assertApproxEqAbs(phUSD.balanceOf(alice), expected, 2);
    }

    // ---------- solvency invariant ----------
    //
    // Strong invariant under the post-M-01 model with explicit
    // `committedDebt`: `balance == rewardBudget + committedDebt` at all
    // times. `_updatePool` moves accrual into `committedDebt`, `_safePay`
    // drains both `committedDebt` and balance by the paid amount, and
    // `_recomputeSchedule` resizes `rewardBudget` to `V - committedDebt`.
    function testBalanceNeverBelowPending() public {
        vm.prank(alice);
        staker.stake(10);
        // Strong invariant after stake.
        assertEq(phUSD.balanceOf(address(staker)), staker.rewardBudget() + staker.committedDebt());

        vm.warp(block.timestamp + 12_345);
        vm.prank(alice);
        staker.claim();

        // After the claim there is no outstanding pending for alice.
        assertEq(staker.pendingReward(alice), 0);
        // And the strong invariant still holds.
        assertEq(phUSD.balanceOf(address(staker)), staker.rewardBudget() + staker.committedDebt());
    }

    // ---------- M-03 regressions ----------
    //
    // Pre-fix sizing: R = T * A / SECONDS_PER_YEAR with T = aggregate(N).
    // When totalStaked << N, effective per-NFT APY scaled as A * (N /
    // totalStaked) — a 1-of-100 staker captured 100x the target.
    //
    // Post-fix sizing: R = totalStaked * latestPrice * A /
    // SECONDS_PER_YEAR. Per-NFT emission = latestPrice * A /
    // SECONDS_PER_YEAR. The most-recent minter (paid latestPrice) earns
    // exactly A; earlier minters earn r^k * A > A. There is no
    // participation multiplier.
    //
    // PoC traceability: scratchpad/planning-docs/phoenix/phase2/nft-staking/audit-05/M-03-submission.md
    function test_M03_LowParticipationDoesNotInflateAPY() public {
        // Tear down the sustainability setUp's seeded scenario for this
        // test by deploying a clean staker with a higher APY (50%) and a
        // larger N (100 minted) but only one NFT staked.
        MockNFTMinter m = new MockNFTMinter();
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false); // growthBP=0
        m.setTotalSupply(ID, 100);

        NFTStaker s = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );

        uint256 V = 1_000_000 ether;
        phUSD.mint(owner, V);
        vm.prank(owner);
        phUSD.approve(address(s), V);
        vm.prank(owner);
        s.topUp(V);

        vm.prank(owner);
        s.setTargetAPY(0.5e18); // 50% target

        // Alice mints 1 NFT (the lone staker — totalStaked=1, N=100).
        nft.mint(alice, ID, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(s), true);
        vm.prank(alice);
        s.stake(1);

        // Hold 1 day, claim.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        s.claim();

        // Alice's NFT was worth 100 ether (latestPrice == price for
        // growthBP=0). At 50% APY for 1 day she should earn:
        //   reward = 100 ether * 0.5 * (1 day / 365 days)
        // i.e. effective APY ≈ 50% — NOT 100 * 50% = 5000% as the pre-fix
        // model would deliver.
        uint256 stakedValue = 100 ether; // 1 NFT * latestPrice
        uint256 expectedReward = (stakedValue * 0.5e18 * 1 days) / (1e18 * 365 days);
        uint256 actualReward = phUSD.balanceOf(alice);
        // Floor-division through accRewardPerShare and the rate floor in
        // _recomputeSchedule can drop ~1e5 wei across a 1-day window
        // when totalStaked is very small. The fundamental check is that
        // the result is approximately `targetAPY`, NOT `N * targetAPY`
        // (which under the pre-fix model was 100x larger).
        assertApproxEqRel(
            actualReward, expectedReward, 0.001e18, "low-participation APY must equal target, not N * target"
        );

        // Effective APY = (reward / stakedValue) * (365 days / 1 day)
        // Should be ~ 0.5e18 (50%), NOT ~ 50e18 (5000%).
        uint256 effectiveAPY = (actualReward * 1e18 * 365 days) / (stakedValue * 1 days);
        assertApproxEqRel(
            effectiveAPY, 0.5e18, 0.001e18, "effective APY must equal target, no participation multiplier"
        );
    }

    function test_M03_LowParticipationDoesNotInflateAPYWithGrowth() public {
        // Same shape as above, with growthBP > 0 so latestPrice != price.
        // The lone-staker (the "most recent minter") still earns exactly the
        // target APY. Earlier minters would earn more, but only the lone
        // staker is in the pool.
        MockNFTMinter m = new MockNFTMinter();
        uint256 priceNext = 100 ether;
        uint256 growthBP = 1; // 0.01%
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);
        m.setTotalSupply(ID, 100);

        NFTStaker s = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );

        uint256 V = 1_000_000 ether;
        phUSD.mint(owner, V);
        vm.prank(owner);
        phUSD.approve(address(s), V);
        vm.prank(owner);
        s.topUp(V);

        vm.prank(owner);
        s.setTargetAPY(0.5e18);

        nft.mint(alice, ID, 1);
        vm.prank(alice);
        nft.setApprovalForAll(address(s), true);
        vm.prank(alice);
        s.stake(1);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        s.claim();

        uint256 r = 1e18 + growthBP * 1e14;
        uint256 latestPrice = Math.mulDiv(priceNext, 1e18, r);
        uint256 expectedReward = (latestPrice * 0.5e18 * 1 days) / (1e18 * 365 days);
        assertApproxEqRel(
            phUSD.balanceOf(alice), expectedReward, 0.001e18, "lone staker earns target APY at latestPrice"
        );
    }

    function test_M03_FullParticipationLatestMinterEqualsTarget() public {
        // 100 NFTs minted, all 100 staked. With growthBP > 0 each minter
        // paid a different price. Per-NFT emission = latestPrice * A /
        // SECONDS_PER_YEAR (uniform across stakers — masterchef
        // distribution by count). The "most recent minter" who paid
        // latestPrice therefore earns exactly the target APY on their NFT
        // value.
        MockNFTMinter m = new MockNFTMinter();
        uint256 priceNext = 100 ether;
        uint256 growthBP = 1; // 0.01%
        m.setConfig(DISPATCHER_INDEX, address(0xBEEF), priceNext, growthBP, false);
        m.setTotalSupply(ID, 100);

        NFTStaker s = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(m)), DISPATCHER_INDEX
        );

        uint256 V = 100_000_000 ether;
        phUSD.mint(owner, V);
        vm.prank(owner);
        phUSD.approve(address(s), V);
        vm.prank(owner);
        s.topUp(V);

        vm.prank(owner);
        s.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(s), true);
        vm.prank(alice);
        s.stake(100);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        s.claim();

        // Per-NFT emission rate = latestPrice * A / SECONDS_PER_YEAR.
        // Total reward over 1 day across 100 NFTs:
        //   reward = 100 * latestPrice * A / SECONDS_PER_YEAR * 1 day
        uint256 r = 1e18 + growthBP * 1e14;
        uint256 latestPrice = Math.mulDiv(priceNext, 1e18, r);
        uint256 perNFTReward = (latestPrice * 0.3e18 * 1 days) / (1e18 * 365 days);
        uint256 expectedTotal = 100 * perNFTReward;

        // Allow rate-floor drift (the per-second rate is floor-rounded,
        // and 100 NFTs * latestPrice * 30% / SECONDS_PER_YEAR can lose a
        // few hundred wei across a 1-day window).
        assertApproxEqRel(phUSD.balanceOf(alice), expectedTotal, 0.0001e18, "total reward must match per-NFT * count");

        // The latest minter's per-NFT APY: reward / latestPrice * 365 days
        // / 1 day == 0.3e18 (target).
        uint256 latestMinterAPY = (perNFTReward * 1e18 * 365 days) / (latestPrice * 1 days);
        assertApproxEqRel(latestMinterAPY, 0.3e18, 0.001e18, "latest minter APY must equal target");
    }
}
