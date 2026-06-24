// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerEmergencyWithdrawTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    event EmergencyWithdrawn(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        vm.prank(owner);
        staker.setPauser(pauser);

        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        // Seed budget + APY so there is pending reward to forfeit.
        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 1_000);
        nft.mint(bob, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
    }

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

        assertEq(nft.balanceOf(alice, ID), 1_000);
        assertEq(staker.totalStaked(), 30);

        (uint256 amt, uint256 debt) = staker.users(alice);
        assertEq(amt, 0);
        assertEq(debt, 0);
    }

    function testForfeitsPendingReward() public {
        vm.prank(alice);
        staker.stake(10);
        vm.warp(block.timestamp + 100);

        uint256 pendingBefore = staker.pendingReward(alice);
        assertGt(pendingBefore, 0);

        uint256 phusdBefore = phUSD.balanceOf(alice);
        uint256 budgetBefore = staker.rewardBudget();

        vm.prank(alice);
        staker.emergencyWithdraw();

        assertEq(phUSD.balanceOf(alice), phusdBefore);
        // emergencyWithdraw does not call _syncBudget / _updatePool.
        assertEq(staker.rewardBudget(), budgetBefore);
    }

    function testCallableWhilePaused() public {
        vm.prank(alice);
        staker.stake(10);

        vm.prank(pauser);
        staker.pause();

        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(nft.balanceOf(alice, ID), 1_000);
    }

    function testWorksWhenDispatcherHookReverts() public {
        vm.prank(alice);
        staker.stake(10);

        hook.setRevertOnPull(true);

        vm.prank(alice);
        vm.expectRevert(bytes("MockHook: pull reverted"));
        staker.claim();

        vm.prank(alice);
        staker.emergencyWithdraw();
        assertEq(nft.balanceOf(alice, ID), 1_000);
    }

    function testRevertsWhenNothingStaked() public {
        vm.prank(alice);
        vm.expectRevert(bytes("NFTStaker: nothing to withdraw"));
        staker.emergencyWithdraw();
    }
}
