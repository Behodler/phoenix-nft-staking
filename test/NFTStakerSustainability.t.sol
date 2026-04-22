// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IBalancerPoolerMintDebtHook
} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {
    MockBalancerPoolerMintDebtHook
} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

contract NFTStakerSustainabilityTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);

    uint256 internal constant ID = 1;
    uint256 internal constant RATE = 100;
    uint256 internal BUDGET;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner
        );

        BUDGET = staker.windowDuration() * RATE;
        phUSD.mint(owner, BUDGET);
        vm.prank(owner);
        phUSD.approve(address(staker), BUDGET);
        vm.prank(owner);
        staker.topUp(BUDGET);

        nft.mint(alice, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------- totalBudget ----------

    function testTotalBudgetWithNoHookEqualsBalance() public {
        // No dispatcher hook configured
        assertEq(address(staker.dispatcherHook()), address(0));
        assertEq(staker.totalBudget(), phUSD.balanceOf(address(staker)));
    }

    function testTotalBudgetIncludesHookMintDebt() public {
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        hook.setPendingMint(12_345);
        assertEq(
            staker.totalBudget(),
            phUSD.balanceOf(address(staker)) + 12_345
        );
    }

    // ---------- totalDebt ----------

    function testTotalDebtZeroWhenNothingAccrued() public {
        // Fresh schedule, no stakers, no time elapsed since lastRewardTime
        // balance == rewardBudget -> debt == 0
        assertEq(staker.totalDebt(), 0);
    }

    function testTotalDebtMatchesPendingForSingleStaker() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);

        uint256 pending = staker.pendingReward(alice);
        assertEq(pending, RATE * 100);
        // Single staker: total debt == that staker's pending
        assertEq(staker.totalDebt(), pending);
    }

    function testTotalDebtPreservedAcrossClaim() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 100);

        uint256 debtBefore = staker.totalDebt();

        vm.prank(alice);
        staker.claim();

        // After claim alice's pending is zero; debt should also drop to ~zero
        // (dust from floor division may remain but is bounded).
        uint256 debtAfter = staker.totalDebt();
        assertLe(debtAfter, debtBefore);
        assertLe(debtAfter, 1); // at most 1 wei dust for single staker
    }

    function testTotalDebtIncludesInFlightAccrual() public {
        vm.prank(alice);
        staker.stake(10);

        // Advance time without triggering _updatePool
        vm.warp(block.timestamp + 50);

        // lastRewardTime hasn't moved but totalDebt simulates accrual
        uint256 expected = RATE * 50;
        assertEq(staker.totalDebt(), expected);
    }

    function testTotalDebtNeverExceedsBalance() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + staker.windowDuration());

        // Full window elapsed — all budget is now debt
        uint256 debt = staker.totalDebt();
        assertLe(debt, phUSD.balanceOf(address(staker)));
    }

    // ---------- runwaySeconds ----------

    function testRunwaySecondsAtFreshScheduleEqualsWindowDuration() public {
        // rate = BUDGET / duration; runway = rewardBudget / rate = duration
        assertEq(staker.runwaySeconds(), staker.windowDuration());
    }

    function testRunwaySecondsIncludesHookMintDebt() public {
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        uint256 extra = staker.rewardRate() * 1_000; // adds 1000s of runway
        hook.setPendingMint(extra);

        assertEq(
            staker.runwaySeconds(),
            (staker.rewardBudget() + extra) / staker.rewardRate()
        );
    }

    function testRunwaySecondsZeroWhenRateIsZero() public {
        // Force a zero rewardRate by setting a window duration larger than
        // remaining budget after partial depletion. Simplest: deploy a fresh
        // staker with no top-up — rate starts at zero.
        NFTStaker bare = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner
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
        // Runway should have shrunk by ~100s (one second per emitted second
        // at constant rate)
        assertApproxEqAbs(runwayStart - runwayMid, 100, 2);
    }

    // ---------- solvency invariant ----------

    function testSolvencyInvariantRewardBudgetPlusDebtLeBalance() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 12_345);
        vm.prank(alice);
        staker.claim();

        // After settlement, balance >= rewardBudget + totalDebt must hold
        uint256 balance = phUSD.balanceOf(address(staker));
        assertGe(balance, staker.rewardBudget() + staker.totalDebt());
    }
}
