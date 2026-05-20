// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerV2} from "../src/NFTStakerV2.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Coverage for the new migrator surface: setMigrator + onlyMigrator-
///         gated stakeFor / unstakeFor. The migrator in these tests is an EOA
///         (per the story spec).
contract NFTStakerV2MigratorTest is Test {
    NFTStakerV2 internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal pauser = address(0xBA);
    // Story spec uses 0xM1G as a mnemonic; converted here to a valid hex literal.
    address internal migratorEOA = address(0x4D16);
    address internal beneficiary = address(0xBE);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;

    event MigratorChanged(address indexed previous, address indexed next);
    event StakedFor(address indexed migrator, address indexed beneficiary, uint256 amount);
    event UnstakedFor(address indexed migrator, address indexed beneficiary, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);

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

        uint256 seed = 10_000_000 ether;
        phUSD.mint(owner, seed);
        vm.prank(owner);
        phUSD.approve(address(staker), seed);
        vm.prank(owner);
        staker.topUp(seed);
        vm.prank(owner);
        staker.setTargetAPY(0.3e18);

        // Migrator EOA gets the NFT supply it will stakeFor on behalf of beneficiary.
        nft.mint(migratorEOA, ID, 100);
        vm.prank(migratorEOA);
        nft.setApprovalForAll(address(staker), true);
    }

    // -----------------------------------------------------------------
    // setMigrator
    // -----------------------------------------------------------------

    function test_setMigrator_happyPath_setsAndEmits() public {
        vm.expectEmit(true, true, false, false, address(staker));
        emit MigratorChanged(address(0), migratorEOA);
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        assertEq(staker.migrator(), migratorEOA);
    }

    function test_setMigrator_strangerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setMigrator(migratorEOA);
    }

    function test_setMigrator_canResetToZero() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        assertEq(staker.migrator(), migratorEOA);

        vm.expectEmit(true, true, false, false, address(staker));
        emit MigratorChanged(migratorEOA, address(0));
        vm.prank(owner);
        staker.setMigrator(address(0));
        assertEq(staker.migrator(), address(0));
    }

    // -----------------------------------------------------------------
    // stakeFor — access guards
    // -----------------------------------------------------------------

    function test_stakeFor_revertsWhenStranger() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.stakeFor(beneficiary, 1);
    }

    function test_stakeFor_revertsWhenMigratorUnset() public {
        // Default migrator is address(0). Even calling from address(0)
        // must revert thanks to the belt-and-braces `migrator != 0` clause.
        vm.prank(address(0));
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.stakeFor(beneficiary, 1);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.stakeFor(beneficiary, 1);
    }

    function test_stakeFor_revertsOnZeroBeneficiary() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: zero beneficiary"));
        staker.stakeFor(address(0), 1);
    }

    function test_stakeFor_revertsOnZeroAmount() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: zero stake"));
        staker.stakeFor(beneficiary, 0);
    }

    function test_stakeFor_revertsWhenPaused() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(pauser);
        staker.pause();

        vm.prank(migratorEOA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staker.stakeFor(beneficiary, 1);
    }

    // -----------------------------------------------------------------
    // stakeFor — happy path
    // -----------------------------------------------------------------

    function test_stakeFor_happyPath_movesNFTsAndUpdatesState() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        uint256 migratorNftBefore = nft.balanceOf(migratorEOA, ID);
        uint256 stakerNftBefore = nft.balanceOf(address(staker), ID);

        vm.expectEmit(true, false, false, true, address(staker));
        emit Staked(beneficiary, 10);
        vm.expectEmit(true, true, false, true, address(staker));
        emit StakedFor(migratorEOA, beneficiary, 10);

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        assertEq(nft.balanceOf(migratorEOA, ID), migratorNftBefore - 10);
        assertEq(nft.balanceOf(address(staker), ID), stakerNftBefore + 10);

        (uint256 amt,) = staker.users(beneficiary);
        assertEq(amt, 10);
        assertEq(staker.totalStaked(), 10);
        // Schedule recompute should have produced a non-zero rate.
        assertGt(staker.rewardRate(), 0);
    }

    function test_stakeFor_existingBeneficiary_paysPendingToBeneficiaryNotMigrator() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        // Accrue for a while.
        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(beneficiary);
        assertGt(pending, 0);

        uint256 benBefore = phUSD.balanceOf(beneficiary);
        uint256 migBefore = phUSD.balanceOf(migratorEOA);

        vm.expectEmit(true, false, false, true, address(staker));
        emit Claimed(beneficiary, pending);

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 5);

        // pending lands on beneficiary, NOT the migrator.
        assertEq(phUSD.balanceOf(beneficiary) - benBefore, pending);
        assertEq(phUSD.balanceOf(migratorEOA), migBefore);
    }

    // -----------------------------------------------------------------
    // unstakeFor — access guards
    // -----------------------------------------------------------------

    function test_unstakeFor_revertsWhenStranger() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        vm.prank(stranger);
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.unstakeFor(beneficiary, 1);
    }

    function test_unstakeFor_revertsWhenMigratorUnset() public {
        // Seed a position via the owner-as-migrator trick: actually easier
        // to set migrator, stake, then unset and try unstaking.
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        vm.prank(owner);
        staker.setMigrator(address(0));

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.unstakeFor(beneficiary, 1);

        vm.prank(address(0));
        vm.expectRevert(bytes("NFTStakerV2: caller is not migrator"));
        staker.unstakeFor(beneficiary, 1);
    }

    function test_unstakeFor_revertsOnZeroBeneficiary() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: zero beneficiary"));
        staker.unstakeFor(address(0), 1);
    }

    function test_unstakeFor_revertsOnZeroAmount() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: zero unstake"));
        staker.unstakeFor(beneficiary, 0);
    }

    function test_unstakeFor_revertsWhenInsufficientStake() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        vm.prank(migratorEOA);
        vm.expectRevert(bytes("NFTStakerV2: insufficient stake"));
        staker.unstakeFor(beneficiary, 11);
    }

    function test_unstakeFor_revertsWhenPaused() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);
        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        vm.prank(pauser);
        staker.pause();

        vm.prank(migratorEOA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        staker.unstakeFor(beneficiary, 1);
    }

    // -----------------------------------------------------------------
    // unstakeFor — happy path
    // -----------------------------------------------------------------

    function test_unstakeFor_happyPath_nftsToMigrator_pendingToBeneficiary() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);

        vm.warp(block.timestamp + 50);
        uint256 pending = staker.pendingReward(beneficiary);
        assertGt(pending, 0);

        uint256 benPhBefore = phUSD.balanceOf(beneficiary);
        uint256 migPhBefore = phUSD.balanceOf(migratorEOA);
        uint256 migNftBefore = nft.balanceOf(migratorEOA, ID);
        uint256 benNftBefore = nft.balanceOf(beneficiary, ID);
        uint256 stakerNftBefore = nft.balanceOf(address(staker), ID);

        vm.expectEmit(true, false, false, true, address(staker));
        emit Claimed(beneficiary, pending);
        vm.expectEmit(true, false, false, true, address(staker));
        emit Unstaked(beneficiary, 10);
        vm.expectEmit(true, true, false, true, address(staker));
        emit UnstakedFor(migratorEOA, beneficiary, 10);

        vm.prank(migratorEOA);
        staker.unstakeFor(beneficiary, 10);

        // NFTs → migrator, NOT beneficiary
        assertEq(nft.balanceOf(migratorEOA, ID) - migNftBefore, 10);
        assertEq(nft.balanceOf(beneficiary, ID), benNftBefore);
        assertEq(nft.balanceOf(address(staker), ID), stakerNftBefore - 10);

        // pending phUSD → beneficiary, NOT migrator
        assertEq(phUSD.balanceOf(beneficiary) - benPhBefore, pending);
        assertEq(phUSD.balanceOf(migratorEOA), migPhBefore);

        // UserInfo / totalStaked debited
        (uint256 amt,) = staker.users(beneficiary);
        assertEq(amt, 0);
        assertEq(staker.totalStaked(), 0);
    }

    // -----------------------------------------------------------------
    // Solvency invariant across migrator-driven cycle
    // -----------------------------------------------------------------

    function test_solvencyInvariant_holdsAcrossStakeForUnstakeForCycle() public {
        vm.prank(owner);
        staker.setMigrator(migratorEOA);

        _assertSolvency();

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 10);
        _assertSolvency();

        vm.warp(block.timestamp + 50);

        vm.prank(migratorEOA);
        staker.stakeFor(beneficiary, 5); // restake path, settles pending
        _assertSolvency();

        vm.warp(block.timestamp + 50);

        vm.prank(migratorEOA);
        staker.unstakeFor(beneficiary, 15);
        _assertSolvency();
    }

    function _assertSolvency() internal view {
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "solvency invariant broken"
        );
    }
}
