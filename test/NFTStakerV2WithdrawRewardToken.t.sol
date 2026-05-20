// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerV2} from "../src/NFTStakerV2.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Coverage for `withdrawRewardToken(to, amount)`: access matrix,
///         guards (totalStaked == 0, paused(), to != 0, amount > 0),
///         happy-path balance and state mutation, event emission.
contract NFTStakerV2WithdrawRewardTokenTest is Test {
    NFTStakerV2 internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBA);
    // Story spec uses 0xM1G as a mnemonic; converted here to a valid hex literal.
    address internal migratorEOA = address(0x4D16);
    address internal stranger = address(0xCAFE);
    address internal sink = address(0x51);
    address internal alice = address(0xA11CE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    event RewardTokenWithdrawn(address indexed to, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100 ether, 0, false);
        nftMinter.setTotalSupply(ID, 100);

        staker = new NFTStakerV2(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );

        vm.prank(owner);
        staker.setPauser(pauser);

        uint256 seed = 1_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        nft.mint(alice, ID, 100);
        vm.prank(alice);
        nft.setApprovalForAll(address(staker), true);
    }

    function _pauseAndPrime() internal {
        vm.prank(pauser);
        staker.pause();
    }

    // -----------------------------------------------------------------
    // Access matrix
    // -----------------------------------------------------------------

    function test_withdrawRewardToken_owner_succeeds() public {
        _pauseAndPrime();
        uint256 bal = phUSD.balanceOf(address(staker));
        vm.prank(owner);
        staker.withdrawRewardToken(sink, bal);
        assertEq(phUSD.balanceOf(sink), bal);
    }

    function test_withdrawRewardToken_migrator_succeeds() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        _pauseAndPrime();

        uint256 bal = phUSD.balanceOf(address(staker));
        vm.prank(migratorEOA);
        staker.withdrawRewardToken(sink, bal);
        assertEq(phUSD.balanceOf(sink), bal);
    }

    function test_withdrawRewardToken_stranger_reverts() public {
        _pauseAndPrime();
        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStakerV2: caller is not owner or migrator"));
        staker.withdrawRewardToken(sink, 1);
    }

    function test_withdrawRewardToken_migratorAsZero_zeroCallerReverts() public {
        // Default migrator is address(0). Even if address(0) tries, the
        // belt-and-braces zero check denies access through the migrator path.
        // Owner check still applies, but address(0) is not the owner either.
        _pauseAndPrime();
        vm.prank(address(0));
        vm.expectRevert(bytes("NFTStakerV2: caller is not owner or migrator"));
        staker.withdrawRewardToken(sink, 1);
    }

    function test_withdrawRewardToken_ownerAfterRenounce_reverts() public {
        // Defensive: a renounced owner must not retain sweep access.
        _pauseAndPrime();

        vm.prank(owner);
        staker.renounceOwnership();
        assertEq(staker.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStakerV2: caller is not owner or migrator"));
        staker.withdrawRewardToken(sink, 1);
    }

    // -----------------------------------------------------------------
    // Guards
    // -----------------------------------------------------------------

    function test_withdrawRewardToken_revertsWhenStakeOutstanding() public {
        vm.prank(alice);
        staker.stake(1);

        _pauseAndPrime();

        vm.prank(owner);
        vm.expectRevert(bytes("NFTStakerV2: stake outstanding"));
        staker.withdrawRewardToken(sink, 1);
    }

    function test_withdrawRewardToken_revertsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStakerV2: not paused"));
        staker.withdrawRewardToken(sink, 1);
    }

    function test_withdrawRewardToken_revertsOnZeroRecipient() public {
        _pauseAndPrime();
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStakerV2: zero recipient"));
        staker.withdrawRewardToken(address(0), 1);
    }

    function test_withdrawRewardToken_revertsOnZeroAmount() public {
        _pauseAndPrime();
        vm.prank(owner);
        vm.expectRevert(bytes("NFTStakerV2: zero withdraw"));
        staker.withdrawRewardToken(sink, 0);
    }

    // -----------------------------------------------------------------
    // Happy path: balance + state + event
    // -----------------------------------------------------------------

    function test_withdrawRewardToken_happyPath_movesBalanceAndResetsState() public {
        _pauseAndPrime();
        uint256 bal = phUSD.balanceOf(address(staker));
        assertGt(bal, 0);

        // Pre-sweep rewardBudget reflects the seeded topUp.
        assertGt(staker.rewardBudget(), 0);
        // committedDebt may already be zero (no stakers yet), but assert it
        // is zero AFTER the sweep regardless.

        vm.expectEmit(true, false, false, true, address(staker));
        emit RewardTokenWithdrawn(sink, bal);

        vm.prank(owner);
        staker.withdrawRewardToken(sink, bal);

        assertEq(phUSD.balanceOf(sink), bal);
        assertEq(phUSD.balanceOf(address(staker)), 0);
        // State mutation: rewardBudget reset to post-sweep balance,
        // committedDebt forced to zero.
        assertEq(staker.rewardBudget(), 0);
        assertEq(staker.committedDebt(), 0);
    }

    function test_withdrawRewardToken_partialSweep_setsBudgetToRemainder() public {
        _pauseAndPrime();
        uint256 bal = phUSD.balanceOf(address(staker));
        uint256 take = bal / 3;

        vm.prank(owner);
        staker.withdrawRewardToken(sink, take);

        assertEq(phUSD.balanceOf(sink), take);
        assertEq(phUSD.balanceOf(address(staker)), bal - take);
        assertEq(staker.rewardBudget(), bal - take);
        assertEq(staker.committedDebt(), 0);
    }
}
