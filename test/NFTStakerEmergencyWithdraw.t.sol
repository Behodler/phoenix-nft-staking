// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

contract NFTStakerEmergencyWithdrawTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;

    event EmergencyWithdrawn(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        vm.prank(owner);
        staker.setPauser(pauser);

        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        // Seed budget via topUp (no need for hook for setup)
        uint256 budget = staker.windowDuration() * 100;
        phUSD.mint(owner, budget);
        vm.prank(owner);
        phUSD.approve(address(staker), budget);
        vm.prank(owner);
        staker.topUp(budget);

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------- principal returned, UserInfo zeroed, totalStaked decremented ----------

    function testReturnsFullPrincipalAndZerosState() public {
        vm.prank(alice);
        staker.stake(50);
        vm.prank(bob);
        staker.stake(30);

        assertEq(staker.totalStaked(), 80);

        vm.expectEmit(true, true, true, true, address(staker));
        emit EmergencyWithdrawn(alice, 50);
        vm.prank(alice);
        staker.emergencyWithdraw();

        // Alice got all 50 back in a single transfer
        assertEq(nft.balanceOf(alice, ID), 1_000);
        // bob untouched
        assertEq(staker.totalStaked(), 30);

        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    // ---------- forfeits pending reward ----------

    function testForfeitsPendingReward() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 100);

        // Sanity: there is something to forfeit
        uint256 pendingBefore = staker.pendingReward(alice);
        assertGt(pendingBefore, 0);

        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 budgetBefore = staker.rewardBudget();

        vm.prank(alice);
        staker.emergencyWithdraw();

        // No phUSD paid
        assertEq(phUSD.balanceOf(alice), phusdBefore);
        // _syncBudget / _updatePool was NOT called: rewardBudget unchanged
        assertEq(staker.rewardBudget(), budgetBefore);
    }

    // ---------- callable while paused ----------

    function testCallableWhilePaused() public {
        vm.prank(alice);
        staker.stake(10);

        vm.prank(pauser);
        staker.pause();

        // Should succeed even while paused
        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(nft.balanceOf(alice, ID), 1_000);
    }

    // ---------- works when dispatcher hook reverts ----------

    function testWorksWhenDispatcherHookReverts() public {
        vm.prank(alice);
        staker.stake(10);

        // Break the hook
        hook.setRevertOnPull(true);

        // Sanity: a normal claim would now revert via _syncBudget -> pull()
        vm.prank(alice);
        vm.expectRevert(bytes("MockHook: pull reverted"));
        staker.claim();

        // emergencyWithdraw must still work
        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(nft.balanceOf(alice, ID), 1_000);
    }

    // ---------- nothing to withdraw revert ----------

    function testRevertsWhenNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: nothing to withdraw"));
        staker.emergencyWithdraw();
    }
}
