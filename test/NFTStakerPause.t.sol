// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerPauseTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

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

        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 1_000);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function testNonPauserCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStaker: caller is not pauser"));
        staker.pause();
    }

    function testOwnerCannotPause() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: caller is not pauser"));
        staker.pause();
    }

    function testStakeRevertsWhenPaused() public {
        vm.prank(pauser);
        staker.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staker.stake(1);
    }

    function testUnstakeRevertsWhenPaused() public {
        vm.prank(alice);
        staker.stake(1);

        vm.prank(pauser);
        staker.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staker.unstake(1);
    }

    function testClaimRevertsWhenPaused() public {
        vm.prank(alice);
        staker.stake(1);

        vm.prank(pauser);
        staker.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staker.claim();
    }

    function testUnpauseRestoresStakeUnstakeClaim() public {
        vm.prank(alice);
        staker.stake(1);

        vm.prank(pauser);
        staker.pause();

        vm.prank(pauser);
        staker.unpause();

        vm.warp(block.timestamp + 10);
        vm.prank(alice);
        staker.claim();
    }
}
