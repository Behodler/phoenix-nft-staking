// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

contract NFTStakerConfigTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBEEF);
    address internal stranger = address(0xCAFE);

    uint256 internal constant INITIAL_ID = 7;

    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event WindowDurationChanged(uint256 previous, uint256 next);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), INITIAL_ID, IERC20(address(phUSD)), owner);
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
    }

    // ---------- constructor ----------

    function testConstructorWiresOwnerStakedTokenIdRewardToken() public view {
        assertEq(staker.owner(), owner);
        assertEq(address(staker.stakedToken()), address(nft));
        assertEq(staker.stakedId(), INITIAL_ID);
        assertEq(address(staker.rewardToken()), address(phUSD));
        assertEq(staker.windowDuration(), staker.DEFAULT_WINDOW());
    }

    function testConstructorRejectsZeroStakedToken() public {
        vm.expectRevert(bytes("NFTStaker: zero staked token"));
        new NFTStaker(IERC1155(address(0)), 1, IERC20(address(phUSD)), owner);
    }

    function testConstructorRejectsZeroRewardToken() public {
        vm.expectRevert(bytes("NFTStaker: zero reward token"));
        new NFTStaker(IERC1155(address(nft)), 1, IERC20(address(0)), owner);
    }

    // ---------- onlyOwner setters ----------

    function testSetDispatcherHookOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
    }

    function testSetWindowDurationOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setWindowDuration(30 days);
    }

    function testSetStakedIdOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setStakedId(99);
    }

    // Note: `topUp`, `pullAndRefresh`, and `setMinPullInterval` are all
    // `onlyOwner`; user-path `_syncBudget` pulls are rate-limited by the
    // `minPullInterval` cooldown. Coverage lives in
    // `NFTStakerPermissions.t.sol`.

    // ---------- setWindowDuration bounds ----------

    function testSetWindowDurationRejectsBelowMin() public {
        uint256 tooSmall = staker.MIN_WINDOW() - 1;
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: window out of bounds"));
        staker.setWindowDuration(tooSmall);
    }

    function testSetWindowDurationRejectsAboveMax() public {
        uint256 tooBig = staker.MAX_WINDOW() + 1;
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: window out of bounds"));
        staker.setWindowDuration(tooBig);
    }

    function testSetWindowDurationAcceptsBoundaries() public {
        vm.startPrank(owner);
        staker.setWindowDuration(staker.MIN_WINDOW());
        assertEq(staker.windowDuration(), staker.MIN_WINDOW());

        staker.setWindowDuration(staker.MAX_WINDOW());
        assertEq(staker.windowDuration(), staker.MAX_WINDOW());
        vm.stopPrank();
    }

    function testSetWindowDurationEmitsEvent() public {
        uint256 prev = staker.windowDuration();
        vm.expectEmit(true, true, true, true, address(staker));
        emit WindowDurationChanged(prev, 30 days);
        vm.prank(owner);
        staker.setWindowDuration(30 days);
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
        // totalStaked == 0 by construction
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
