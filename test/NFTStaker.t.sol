// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract NFTStakerTest is Test {
    NFTStaker internal staker;
    address internal deployer = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        vm.prank(deployer);
        staker = new NFTStaker();
    }

    function testConstructorSetsOwnerToMsgSender() public view {
        assertEq(staker.owner(), deployer);
    }

    function testSetPauserOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setPauser(pauser);
    }

    function testSetPauserUpdatesPauser() public {
        vm.prank(deployer);
        staker.setPauser(pauser);
        assertEq(staker.pauser(), pauser);
    }

    function testPauseOnlyCallableByPauser() public {
        vm.prank(deployer);
        staker.setPauser(pauser);

        vm.prank(stranger);
        vm.expectRevert();
        staker.pause();

        vm.prank(deployer);
        vm.expectRevert();
        staker.pause();

        vm.prank(pauser);
        staker.pause();
        assertTrue(staker.paused());
    }

    function testUnpauseOnlyCallableByPauser() public {
        vm.prank(deployer);
        staker.setPauser(pauser);

        vm.prank(pauser);
        staker.pause();

        vm.prank(stranger);
        vm.expectRevert();
        staker.unpause();

        vm.prank(pauser);
        staker.unpause();
        assertFalse(staker.paused());
    }

    function testImplementsIPausable() public {
        vm.prank(deployer);
        staker.setPauser(pauser);

        IPausable ip = IPausable(address(staker));
        assertEq(ip.pauser(), pauser);

        vm.prank(pauser);
        ip.pause();
        assertTrue(staker.paused());

        vm.prank(pauser);
        ip.unpause();
        assertFalse(staker.paused());
    }
}
