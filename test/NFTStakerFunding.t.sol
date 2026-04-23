// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

contract NFTStakerFundingTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    uint256 internal constant INITIAL_ID = 1;

    event Pulled(uint256 inflow, uint256 newBudget, uint256 newRate, uint256 newWindowEnd);
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget, uint256 newRate);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), INITIAL_ID, IERC20(address(phUSD)), owner);
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
    }

    // ---------- pullAndRefresh: nonzero pull ----------

    function testNonzeroPullIncrementsBudgetAndResetsWindow() public {
        uint256 amount = 540 days * 100; // tidy rate of 100 phUSD/sec
        hook.setPendingMint(amount);

        vm.expectEmit(true, true, true, true, address(staker));
        emit Pulled(amount, amount, amount / staker.windowDuration(), block.timestamp + staker.windowDuration());

        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardBudget(), amount);
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
        assertEq(staker.rewardRate(), amount / staker.windowDuration());
    }

    function testNonzeroPullResetsWindowEvenMidLife() public {
        // First pull to set baseline
        uint256 firstAmount = 540 days * 50;
        hook.setPendingMint(firstAmount);
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 firstEnd = staker.windowEnd();

        vm.warp(block.timestamp + 10 days);

        uint256 secondAmount = 540 days * 50;
        hook.setPendingMint(secondAmount);
        vm.prank(owner);
        staker.pullAndRefresh();

        // Window should reset to now+windowDuration, not the original end
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
        assertGt(staker.windowEnd(), firstEnd);

        // Budget grew by the new inflow, less anything accrued (no stakers => no accrual)
        assertEq(staker.rewardBudget(), firstAmount + secondAmount);
        assertEq(staker.rewardRate(), staker.rewardBudget() / staker.windowDuration());
    }

    // ---------- pullAndRefresh: zero pull ----------

    function testZeroPullIsNoOp() public {
        // No pending mint set
        hook.setPendingMint(0);

        // Establish a baseline schedule via topUp first
        uint256 amount = 540 days * 100;
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);
        vm.prank(owner);
        staker.topUp(amount);

        uint256 budgetBefore = staker.rewardBudget();
        uint256 rateBefore = staker.rewardRate();
        uint256 endBefore = staker.windowEnd();

        // Recorder for expectEmit not needed: we want to prove no Pulled event fires.
        vm.recordLogs();
        vm.prank(owner);
        staker.pullAndRefresh();
        // Iterate logs and assert none has the Pulled signature
        bytes32 pulledSig = keccak256("Pulled(uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != pulledSig, "Pulled emitted on zero inflow");
            }
        }

        assertEq(staker.rewardBudget(), budgetBefore);
        assertEq(staker.rewardRate(), rateBefore);
        assertEq(staker.windowEnd(), endBefore);
    }

    function testPullWithUnsetHookIsNoOp() public {
        // Reset the hook to zero
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(0)));
        // Should not revert and should not change state
        vm.prank(owner);
        staker.pullAndRefresh();
        assertEq(staker.rewardBudget(), 0);
        assertEq(staker.rewardRate(), 0);
        assertEq(staker.windowEnd(), 0);
    }

    // ---------- topUp ----------

    function testTopUpIncrementsBudgetAndResetsWindow() public {
        uint256 amount = 540 days * 100;
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);

        vm.expectEmit(true, true, true, true, address(staker));
        emit ToppedUp(owner, amount, amount, amount / staker.windowDuration());

        vm.prank(owner);
        staker.topUp(amount);

        assertEq(staker.rewardBudget(), amount);
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration());
        assertEq(staker.rewardRate(), amount / staker.windowDuration());
        assertEq(phUSD.balanceOf(address(staker)), amount);
    }

    function testTopUpRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }

    // ---------- setWindowDuration is config-only ----------

    function testSetWindowDurationIsConfigOnly() public {
        // Fund first — seeds rewardRate_0 and windowEnd_0.
        uint256 amount = 540 days * 100;
        hook.setPendingMint(amount);
        vm.prank(owner);
        staker.pullAndRefresh();

        uint256 rate0 = staker.rewardRate();
        uint256 end0 = staker.windowEnd();
        assertGt(rate0, 0);
        assertGt(end0, 0);

        uint256 newDuration = 90 days;
        vm.prank(owner);
        staker.setWindowDuration(newDuration);

        // Setter is config-only: neither rewardRate nor windowEnd should
        // shift at the setter call itself.
        assertEq(staker.windowDuration(), newDuration);
        assertEq(staker.rewardRate(), rate0, "setter must not rewrite rewardRate");
        assertEq(staker.windowEnd(), end0, "setter must not rewrite windowEnd");

        // A subsequent nonzero-inflow pullAndRefresh under a shorter
        // duration raises rewardRate — the "next qualifying pull rescales"
        // property (candidate = (budget + inflow) / newDuration > rate0).
        uint256 extra = 1 ether;
        hook.setPendingMint(extra);
        vm.prank(owner);
        staker.pullAndRefresh();

        uint256 newRate = staker.rewardRate();
        assertGt(newRate, rate0, "qualifying inflow must raise rate after shortened window");
        assertEq(newRate, staker.rewardBudget() / newDuration, "new rate = budget / newDuration");
        assertEq(staker.windowEnd(), block.timestamp + newDuration, "windowEnd should reset on rate raise");
    }
}
