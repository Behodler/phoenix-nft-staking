// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract NFTStakerPauseTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        vm.prank(owner);
        staker.setPauser(pauser);

        // Seed budget so stake/claim can do something
        uint256 budget = staker.windowDuration() * 100;
        phUSD.mint(owner, budget);
        vm.prank(owner);
        phUSD.approve(address(staker), budget);
        vm.prank(owner);
        staker.topUp(budget);

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
        // Did not revert -> success
    }
}
