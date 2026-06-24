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

/// @notice Owner-only gating on the funding and policy surface.
///
///         Under the variable-runway / APY-target model the old monotonic-
///         upward `rewardRate` invariant is moot: R is determined by T*A,
///         independent of inflow cadence. The griefing surface covered by
///         the previous iteration of this file (audit M-01: dry-trickle
///         rate collapse) is structurally absent in the new model — there
///         is no rate-writing code path that depends on inflow size.
///
///         What remains is permission gating on the setters and the
///         empty-pool guard on `setDispatcherIndex` / `setNFTMinter`. The
///         empty-pool guard is the analog of `setStakedId`'s guard: a
///         mid-stake swap of the minter or dispatcher could move the APY
///         computation to a different NFT and is therefore disallowed.
contract NFTStakerPermissionsTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal stranger = address(0xBEEF);
    address internal user = address(0xA1);

    uint256 internal constant INITIAL_ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant STAKE_AMOUNT = 10;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(INITIAL_ID, 100);

        staker = new NFTStaker(
            IERC1155(address(nft)),
            INITIAL_ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        nft.mint(user, INITIAL_ID, STAKE_AMOUNT);
        vm.prank(user);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------- onlyOwner gating ----------

    function test_nonOwner_pullAndRefresh_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.pullAndRefresh();
    }

    function test_nonOwner_topUp_reverts() public {
        phUSD.mint(stranger, 1);
        vm.prank(stranger);
        phUSD.approve(address(staker), 1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.topUp(1);
    }

    function test_nonOwner_setTargetAPY_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setTargetAPY(0.2e18);
    }

    function test_nonOwner_setDispatcherIndex_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setDispatcherIndex(2);
    }

    function test_nonOwner_setNFTMinter_reverts() public {
        MockNFTMinter other = new MockNFTMinter();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setNFTMinter(INFTSupply(address(other)));
    }

    // ---------- empty-pool guards ----------

    function test_setDispatcherIndex_revertsWhenStakeOutstanding() public {
        // Seed budget + APY so stake accrues.
        uint256 seed = 1_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        vm.prank(user);
        staker.stake(1);

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setDispatcherIndex(2);
    }

    function test_setNFTMinter_revertsWhenStakeOutstanding() public {
        uint256 seed = 1_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        vm.prank(user);
        staker.stake(1);

        MockNFTMinter other = new MockNFTMinter();
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        staker.setNFTMinter(INFTSupply(address(other)));
    }

    // ---------- topUp zero guard ----------

    function test_topUp_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStaker: zero topUp"));
        staker.topUp(0);
    }
}
