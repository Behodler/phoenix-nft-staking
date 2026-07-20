// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerDepletion} from "../src/NFTStakerDepletion.sol";
import {NFTStakerMigrator} from "../src/NFTStakerMigrator.sol";
import {InPlaceNFTStakerMigrator} from "../src/InPlaceNFTStakerMigrator.sol";
import {INFTStakerMigratable} from "../src/INFTStakerMigratable.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Orchestrator tests for `NFTStakerMigrator` (cross-staker) and
///         `InPlaceNFTStakerMigrator` (in-place rewire): cross-staker happy
///         path + empty-batch short-circuit + permission negatives; in-place
///         out -> swap -> in round-trip, permissionless `claimTimedOut`,
///         `rescueERC20`/`rescueERC1155` parked floor.
contract NFTStakerMigratorOrchestratorsTest is Test {
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA01);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_MONTH = 365 days / 12;
    uint256 internal constant TIMEOUT = 7 days;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);
    }

    function _newStaker(uint256 stakedId) internal returns (NFTStakerDepletion s) {
        s = new NFTStakerDepletion(
            IERC1155(address(nft)),
            stakedId,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
    }

    function _stakeAs(NFTStakerDepletion s, address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.prank(who);
        nft.setApprovalForAll(address(s), true);
        vm.prank(who);
        s.stake(amount);
    }

    // ===================================================================
    // Cross-staker: NFTStakerMigrator
    // ===================================================================

    function testCrossStakerHappyPath() public {
        NFTStakerDepletion oldStaker = _newStaker(ID);
        NFTStakerDepletion newStaker = _newStaker(ID);

        _stakeAs(oldStaker, alice, 5);
        _stakeAs(oldStaker, bob, 3);
        phUSD.mint(address(oldStaker), 1_000_000 ether);
        vm.prank(owner);
        oldStaker.setDepletionWindow(12);
        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = oldStaker.pendingReward(alice);

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        // Wire the migrator as migrator on BOTH stakers.
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        vm.prank(owner);
        newStaker.setMigrator(address(mig));

        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = bob;
        vm.prank(owner);
        mig.migrate(u);

        // Old staker drained, new staker credited the SAME users.
        assertEq(oldStaker.totalStaked(), 0, "old drained");
        assertEq(newStaker.totalStaked(), 8, "new total");
        (uint256 aNew,) = newStaker.userInfo(alice);
        (uint256 bNew,) = newStaker.userInfo(bob);
        assertEq(aNew, 5, "alice migrated to new");
        assertEq(bNew, 3, "bob migrated to new");
        assertEq(nft.balanceOf(address(newStaker), ID), 8, "new staker holds stake");
        assertEq(nft.balanceOf(address(mig), ID), 0, "migrator holds nothing after");

        // Reward was settled to alice during migrate-out.
        assertEq(phUSD.balanceOf(alice), alicePending, "alice reward minted at migrate-out");
    }

    function testCrossStakerEmptyBatchShortCircuits() public {
        NFTStakerDepletion oldStaker = _newStaker(ID);
        NFTStakerDepletion newStaker = _newStaker(ID);
        phUSD.mint(address(oldStaker), 1 ether);
        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        vm.prank(owner);
        newStaker.setMigrator(address(mig));
        vm.prank(owner);
        mig.initiateMigration();

        // No stakers -> empty batch, no revert, nothing credited.
        address[] memory u = new address[](1);
        u[0] = stranger;
        vm.prank(owner);
        mig.migrate(u);
        assertEq(newStaker.totalStaked(), 0, "nothing credited on empty batch");
    }

    function testCrossStakerMigrateOnlyOwner() public {
        NFTStakerDepletion oldStaker = _newStaker(ID);
        NFTStakerDepletion newStaker = _newStaker(ID);
        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert();
        vm.prank(stranger);
        mig.migrate(u);
    }

    function testCrossStakerRejectsZeroAndSame() public {
        NFTStakerDepletion s = _newStaker(ID);
        vm.expectRevert(bytes("Migrator: zero old staker"));
        new NFTStakerMigrator(
            INFTStakerMigratable(address(0)), s, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner
        );
        vm.expectRevert(bytes("Migrator: same staker"));
        new NFTStakerMigrator(s, s, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
    }

    // ===================================================================
    // In-place: InPlaceNFTStakerMigrator
    // ===================================================================

    function _deployInPlace(NFTStakerDepletion s) internal returns (InPlaceNFTStakerMigrator mig) {
        mig = new InPlaceNFTStakerMigrator(s, IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        s.setMigrator(address(mig));
    }

    function testInPlaceRoundTripWithDispatcherSwap() public {
        NFTStakerDepletion s = _newStaker(ID);
        _stakeAs(s, alice, 5);
        _stakeAs(s, bob, 3);
        phUSD.mint(address(s), 1_000_000 ether);
        vm.prank(owner);
        s.setDepletionWindow(12);
        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = s.pendingReward(alice);

        InPlaceNFTStakerMigrator mig = _deployInPlace(s);

        // OUT: park alice + bob.
        vm.prank(owner);
        mig.initiateMigration();
        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = bob;
        vm.prank(owner);
        mig.migrateOut(u);

        assertEq(mig.totalParked(), 8, "8 parked");
        assertEq(mig.parked(alice), 5, "alice parked 5");
        assertEq(nft.balanceOf(address(mig), ID), 8, "migrator custodies stake");
        assertEq(s.totalStaked(), 0, "staker drained");
        assertEq(phUSD.balanceOf(alice), alicePending, "reward minted at out");

        // SWAP: the empty-pool-gated rewire (dispatcherIndex) — only possible
        // because the pool is drained. Reset first to flip back to Active.
        vm.prank(owner);
        s.finalizeAndReset();
        vm.prank(owner);
        s.setDispatcherIndex(2);
        assertEq(s.dispatcherIndex(), 2, "dispatcher index swapped");

        // IN: re-inject everyone.
        vm.prank(owner);
        mig.migrateIn(0, 2);

        assertEq(mig.totalParked(), 0, "nothing parked after in");
        assertEq(s.totalStaked(), 8, "stake restored");
        (uint256 aAmt,) = s.userInfo(alice);
        (uint256 bAmt,) = s.userInfo(bob);
        assertEq(aAmt, 5, "alice restored");
        assertEq(bAmt, 3, "bob restored");
        assertEq(nft.balanceOf(address(mig), ID), 0, "migrator holds nothing after in");
    }

    function testInPlaceMigrateOutIdempotent() public {
        NFTStakerDepletion s = _newStaker(ID);
        _stakeAs(s, alice, 4);
        phUSD.mint(address(s), 1_000_000 ether);
        vm.prank(owner);
        s.setDepletionWindow(12);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(owner);
        mig.migrateOut(u);
        assertEq(mig.totalParked(), 4, "parked once");

        // Re-run: already-migrated -> 0, no double-park.
        vm.prank(owner);
        mig.migrateOut(u);
        assertEq(mig.totalParked(), 4, "no double-park");
        assertEq(mig.parked(alice), 4, "parked unchanged");
    }

    function testInPlaceClaimTimedOut() public {
        NFTStakerDepletion s = _newStaker(ID);
        _stakeAs(s, alice, 5);
        phUSD.mint(address(s), 1_000_000 ether);
        vm.prank(owner);
        s.setDepletionWindow(12);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        vm.prank(owner);
        mig.initiateMigration();
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(owner);
        mig.migrateOut(u);

        // Too early -> reverts.
        vm.expectRevert(bytes("InPlace: timeout not elapsed"));
        vm.prank(alice);
        mig.claimTimedOut();

        // After timeout -> alice reclaims her stake.
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.prank(alice);
        mig.claimTimedOut();
        assertEq(nft.balanceOf(alice, ID), 5, "alice reclaimed stake");
        assertEq(mig.totalParked(), 0, "parked cleared");
        assertEq(mig.parked(alice), 0, "alice parked cleared");
    }

    function testInPlaceClaimTimedOutSelfOnly() public {
        NFTStakerDepletion s = _newStaker(ID);
        _stakeAs(s, alice, 5);
        phUSD.mint(address(s), 1_000_000 ether);
        vm.prank(owner);
        s.setDepletionWindow(12);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        vm.prank(owner);
        mig.initiateMigration();
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(owner);
        mig.migrateOut(u);
        vm.warp(block.timestamp + TIMEOUT + 1);

        // Stranger has nothing parked.
        vm.expectRevert(bytes("InPlace: nothing parked"));
        vm.prank(stranger);
        mig.claimTimedOut();
    }

    function testInPlaceMigrateOutOnlyOwner() public {
        NFTStakerDepletion s = _newStaker(ID);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert();
        vm.prank(stranger);
        mig.migrateOut(u);
    }

    function testInPlaceTimeoutBoundsEnforced() public {
        NFTStakerDepletion s = _newStaker(ID);
        vm.expectRevert(bytes("InPlace: timeout out of bounds"));
        new InPlaceNFTStakerMigrator(s, IERC1155(address(nft)), ID, 1 hours, IERC20(address(phUSD)), owner);
        vm.expectRevert(bytes("InPlace: timeout out of bounds"));
        new InPlaceNFTStakerMigrator(s, IERC1155(address(nft)), ID, 60 days, IERC20(address(phUSD)), owner);
    }

    // -------------------------------------------------------------------
    // rescue floors
    // -------------------------------------------------------------------

    function testInPlaceRescueERC1155FlooredAtParked() public {
        NFTStakerDepletion s = _newStaker(ID);
        _stakeAs(s, alice, 5);
        phUSD.mint(address(s), 1_000_000 ether);
        vm.prank(owner);
        s.setDepletionWindow(12);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        vm.prank(owner);
        mig.initiateMigration();
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(owner);
        mig.migrateOut(u);

        // 5 parked. Donate 3 surplus of the staked id.
        nft.mint(address(mig), ID, 3);
        assertEq(nft.balanceOf(address(mig), ID), 8, "5 parked + 3 surplus");

        // Cannot rescue into the parked floor.
        vm.expectRevert(bytes("InPlace: cannot touch parked principal"));
        vm.prank(owner);
        mig.rescueERC1155(ID, bob, 4);

        // Can rescue exactly the surplus.
        vm.prank(owner);
        mig.rescueERC1155(ID, bob, 3);
        assertEq(nft.balanceOf(bob, ID), 3, "surplus rescued");
        assertEq(nft.balanceOf(address(mig), ID), 5, "parked floor intact");
    }

    function testInPlaceRescueERC20Sweep() public {
        NFTStakerDepletion s = _newStaker(ID);
        InPlaceNFTStakerMigrator mig = _deployInPlace(s);
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(mig), 1_000 ether);

        vm.expectRevert(bytes("InPlace: zero recipient"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(other)), address(0), 1_000 ether);

        vm.expectRevert();
        vm.prank(stranger);
        mig.rescueERC20(IERC20(address(other)), bob, 1_000 ether);

        vm.prank(owner);
        mig.rescueERC20(IERC20(address(other)), bob, 1_000 ether);
        assertEq(other.balanceOf(bob), 1_000 ether, "erc20 swept");
    }
}
