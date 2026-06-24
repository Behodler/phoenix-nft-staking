// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

contract NFTStakerConfigTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    uint256 internal constant INITIAL_ID = 7;
    uint256 internal constant DISPATCHER_INDEX = 1;

    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event TargetAPYChanged(uint256 previous, uint256 next);
    event DispatcherIndexChanged(uint256 previous, uint256 next);
    event NFTMinterChanged(address indexed previous, address indexed next);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 1, false);
        staker = new NFTStaker(
            IERC1155(address(nft)),
            INITIAL_ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
    }

    // ---------- constructor ----------

    function testConstructorWiresConfig() public view {
        assertEq(staker.owner(), owner);
        assertEq(address(staker.stakedToken()), address(nft));
        assertEq(staker.stakedId(), INITIAL_ID);
        assertEq(address(staker.rewardToken()), address(phUSD));
        assertEq(address(staker.nftMinter()), address(nftMinter));
        assertEq(staker.dispatcherIndex(), DISPATCHER_INDEX);
        assertEq(staker.targetAPY(), 0);
    }

    function testConstructorRejectsZeroStakedToken() public {
        vm.expectRevert(bytes("NFTStaker: zero staked token"));
        new NFTStaker(
            IERC1155(address(0)), 1, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
    }

    function testConstructorRejectsZeroRewardToken() public {
        vm.expectRevert(bytes("NFTStaker: zero reward token"));
        new NFTStaker(
            IERC1155(address(nft)), 1, IERC20(address(0)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
    }

    function testConstructorRejectsZeroNFTMinter() public {
        vm.expectRevert(bytes("NFTStaker: zero nft minter"));
        new NFTStaker(
            IERC1155(address(nft)), 1, IERC20(address(phUSD)), owner, INFTSupply(address(0)), DISPATCHER_INDEX
        );
    }

    // ---------- onlyOwner setters ----------

    function testSetDispatcherHookOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
    }

    function testSetStakedIdOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setStakedId(99);
    }

    function testSetTargetAPYOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setTargetAPY(0.3e18);
    }

    function testSetDispatcherIndexOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setDispatcherIndex(2);
    }

    function testSetNFTMinterOnlyOwner() public {
        MockNFTMinter other = new MockNFTMinter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setNFTMinter(INFTSupply(address(other)));
    }

    // ---------- setTargetAPY bounds ----------

    function testSetTargetAPYRejectsAboveMax() public {
        uint256 tooBig = staker.MAX_TARGET_APY() + 1;
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: APY too high"));
        staker.setTargetAPY(tooBig);
    }

    function testSetTargetAPYAcceptsMaxBoundary() public {
        uint256 max = staker.MAX_TARGET_APY();
        vm.prank(owner);
        staker.setTargetAPY(max);
        assertEq(staker.targetAPY(), max);
    }

    function testSetTargetAPYEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit TargetAPYChanged(0, 0.3e18);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);
    }

    // ---------- setDispatcherIndex guard / event ----------

    function testSetDispatcherIndexEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit DispatcherIndexChanged(DISPATCHER_INDEX, 42);
        vm.prank(owner);
        staker.setDispatcherIndex(42);
        assertEq(staker.dispatcherIndex(), 42);
    }

    // ---------- setNFTMinter guard / event ----------

    function testSetNFTMinterEmitsEvent() public {
        MockNFTMinter other = new MockNFTMinter();
        vm.expectEmit(true, true, true, true, address(staker));
        emit NFTMinterChanged(address(nftMinter), address(other));
        vm.prank(owner);
        staker.setNFTMinter(INFTSupply(address(other)));
        assertEq(address(staker.nftMinter()), address(other));
    }

    function testSetNFTMinterRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero nft minter"));
        staker.setNFTMinter(INFTSupply(address(0)));
    }

    // ---------- setDispatcherHook ----------

    function testSetDispatcherHookEmitsEventAndStores() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit DispatcherHookChanged(address(0), address(hook));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
        assertEq(address(staker.dispatcherHook()), address(hook));
    }

    function testSetDispatcherHookCanRotate() public {
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        MockBalancerPoolerMintDebtHook newHook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.expectEmit(true, true, true, true, address(staker));
        emit DispatcherHookChanged(address(hook), address(newHook));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(newHook)));
        assertEq(address(staker.dispatcherHook()), address(newHook));
    }

    // ---------- setStakedId emit ----------

    function testSetStakedIdEmitsEventWhenAllowed() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit StakedIdChanged(INITIAL_ID, 42);
        vm.prank(owner);
        staker.setStakedId(42);
        assertEq(staker.stakedId(), 42);
    }

    // ---------- pauser change emits ----------

    function testSetPauserEmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(staker));
        emit PauserChanged(address(0), pauser);
        vm.prank(owner);
        staker.setPauser(pauser);
    }
}
