// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerIdChangeTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);

    uint256 internal constant ID_A = 1;
    uint256 internal constant ID_B = 2;
    uint256 internal constant DISPATCHER_INDEX = 1;

    event StakedIdChanged(uint256 previous, uint256 next);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID_A, 100);
        nftMinter.setTotalSupply(ID_B, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)),
            ID_A,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );

        vm.prank(owner);
        staker.setPauser(pauser);

        // Seed budget + APY.
        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID_A, 1_000);
        nft.mint(alice, ID_B, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function testSetStakedIdSucceedsWhenTotalStakedZero() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit StakedIdChanged(ID_A, ID_B);
        vm.prank(owner);
        staker.setStakedId(ID_B);
        assertEq(staker.stakedId(), ID_B);
    }

    function testSetStakedIdRevertsWhenStakeOutstanding() public {
        vm.prank(alice);
        staker.stake(1);
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setStakedId(ID_B);
    }

    function testMigrationViaUnstake() public {
        vm.prank(alice);
        staker.stake(10);

        vm.warp(block.timestamp + 100);
        uint256 expectedReward = staker.rewardRate() * 100;

        vm.prank(alice);
        staker.unstake(10);

        assertEq(nft.balanceOf(alice, ID_A), 1_000);
        assertEq(phUSD.balanceOf(alice), expectedReward);
        assertEq(staker.totalStaked(), 0);

        vm.prank(owner);
        staker.setStakedId(ID_B);

        vm.prank(alice);
        staker.stake(20);
        assertEq(nft.balanceOf(address(staker), ID_B), 20);

        vm.warp(block.timestamp + 50);
        assertEq(staker.pendingReward(alice), staker.rewardRate() * 50);
    }

    function testMigrationViaEmergencyWithdraw() public {
        vm.prank(alice);
        staker.stake(10);

        vm.prank(pauser);
        staker.pause();

        uint256 phusdBefore = phUSD.balanceOf(alice);
        vm.prank(alice);
        staker.emergencyWithdraw();

        assertEq(nft.balanceOf(alice, ID_A), 1_000);
        assertEq(phUSD.balanceOf(alice), phusdBefore);

        vm.prank(owner);
        staker.setStakedId(ID_B);
        vm.prank(pauser);
        staker.unpause();

        vm.prank(alice);
        staker.stake(5);
        assertEq(nft.balanceOf(address(staker), ID_B), 5);
    }
}
