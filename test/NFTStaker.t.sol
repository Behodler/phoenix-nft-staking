// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerTest is Test {
    NFTStaker internal staker;
    MockNFTMinter internal nftMinter;

    address internal deployer = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    // Dummy non-zero placeholder addresses for the staked / reward tokens —
    // this suite only exercises the pause / owner surface; dedicated suites
    // use full mocks.
    address internal stakedTokenAddr = address(0x1155);
    address internal rewardTokenAddr = address(0x20);
    uint256 internal initialStakedId = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    function setUp() public {
        nftMinter = new MockNFTMinter();
        staker = new NFTStaker(
            IERC1155(stakedTokenAddr),
            initialStakedId,
            IERC20(rewardTokenAddr),
            deployer,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
    }

    function testConstructorSetsOwnerToInitialOwner() public view {
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
