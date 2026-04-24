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

contract NFTStakerERC1155Test is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);

    uint256 internal constant STAKED_ID = 1;
    uint256 internal constant FOREIGN_ID = 999;
    uint256 internal constant DISPATCHER_INDEX = 1;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(STAKED_ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)),
            STAKED_ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );

        nft.mint(alice, STAKED_ID, 100);
        nft.mint(alice, FOREIGN_ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function testStakeAcceptsConfiguredIdOnly() public {
        vm.prank(alice);
        staker.stake(5);
        assertEq(nft.balanceOf(address(staker), STAKED_ID), 5);
        assertEq(staker.totalStaked(), 5);
    }

    function testForeignIdTransferIsAcceptedButNotAccounted() public {
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(staker), FOREIGN_ID, 10, "");
        assertEq(nft.balanceOf(address(staker), FOREIGN_ID), 10);

        assertEq(staker.totalStaked(), 0);
        (uint256 amt,) = staker.users(alice);
        assertEq(amt, 0);
    }
}
