// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerPriceScaledMigrateReady} from "../src/NFTStakerPriceScaledMigrateReady.sol";
import {NFTStakerDepletion} from "../src/NFTStakerDepletion.sol";
import {NFTStakerMigrator} from "../src/NFTStakerMigrator.sol";
import {InPlaceNFTStakerMigrator} from "../src/InPlaceNFTStakerMigrator.sol";
import {INFTStakerMigratable} from "../src/INFTStakerMigratable.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Proves the story-019 orchestrators — `NFTStakerMigrator` and
///         `InPlaceNFTStakerMigrator` — work against
///         `NFTStakerPriceScaledMigrateReady` with **NO source changes** to
///         either migrator. Both are typed entirely against
///         `INFTStakerMigratable` with zero coupling to the depletion model, so
///         the only requirement is that the new staker `is
///         INFTStakerMigratable` with matching semantics. Covers: cross-staker
///         PriceScaled -> PriceScaled, cross-MODEL Depletion -> PriceScaled
///         (interface is model-agnostic), the in-place park/rewire/return
///         cycle, and the two silent wiring-failure modes (migrator not set on
///         both stakers; target staker not `Active`).
contract NFTStakerPriceScaledMigratorOrchestratorsTest is Test {
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal migrator = address(0x319A);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA01);
    address internal stranger = address(0xCAFE);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant ALT_DISPATCHER_INDEX = 2;
    uint256 internal constant PRICE_SCALE = 1e12;
    uint256 internal constant TARGET_APY = 0.45e18;
    uint256 internal constant BUDGET = 1_000_000 ether;
    uint256 internal constant TIMEOUT = 7 days;

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        // Second, differently-priced dispatcher for the in-place rewire.
        nftMinter.setConfig(ALT_DISPATCHER_INDEX, address(0xFEED), 250e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);
    }

    // ----- helpers -----

    function _newPriceScaled(uint256 stakedId) internal returns (NFTStakerPriceScaledMigrateReady s) {
        s = new NFTStakerPriceScaledMigrateReady(
            IERC1155(address(nft)),
            stakedId,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            PRICE_SCALE
        );
    }

    function _newDepletion(uint256 stakedId) internal returns (NFTStakerDepletion s) {
        s = new NFTStakerDepletion(
            IERC1155(address(nft)),
            stakedId,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX
        );
    }

    function _stakeAs(address stakerAddr, address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.prank(who);
        nft.setApprovalForAll(stakerAddr, true);
        vm.prank(who);
        (bool ok,) = stakerAddr.call(abi.encodeWithSignature("stake(uint256)", amount));
        require(ok, "stake failed");
    }

    function _fundPriceScaled(NFTStakerPriceScaledMigrateReady s) internal {
        phUSD.mint(address(s), BUDGET);
        vm.prank(owner);
        s.setTargetAPY(TARGET_APY);
    }

    // ===================================================================
    // Cross-staker: unmodified NFTStakerMigrator, PriceScaled -> PriceScaled
    // ===================================================================

    function testCrossStakerHappyPathPriceScaledToPriceScaled() public {
        NFTStakerPriceScaledMigrateReady oldStaker = _newPriceScaled(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);

        _stakeAs(address(oldStaker), alice, 5);
        _stakeAs(address(oldStaker), bob, 3);
        _fundPriceScaled(oldStaker);
        // The target needs its own budget so the migrated-in pool has runway.
        _stakeAs(address(newStaker), carol, 1);
        _fundPriceScaled(newStaker);

        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = oldStaker.pendingReward(alice);
        assertGt(alicePending, 0, "alice accrued on the old staker");

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        // Wire the migrator as migrator on BOTH stakers.
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        vm.prank(owner);
        newStaker.setMigrator(address(mig));

        uint256 newRateBefore = newStaker.rewardRate();

        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = bob;
        vm.prank(owner);
        mig.migrate(u);

        // Old staker drained, new staker credited the SAME users.
        assertEq(oldStaker.totalStaked(), 0, "old drained");
        assertEq(newStaker.totalStaked(), 9, "new total == 1 incumbent + 8 migrated");
        (uint256 aNew,) = newStaker.userInfo(alice);
        (uint256 bNew,) = newStaker.userInfo(bob);
        assertEq(aNew, 5, "alice migrated to new");
        assertEq(bNew, 3, "bob migrated to new");
        assertEq(nft.balanceOf(address(newStaker), ID), 9, "new staker holds stake");
        assertEq(nft.balanceOf(address(mig), ID), 0, "migrator holds nothing after");

        // Reward was settled to alice (not the migrator) during migrate-out.
        assertEq(phUSD.balanceOf(alice), alicePending, "alice reward paid at migrate-out");
        assertEq(phUSD.balanceOf(address(mig)), 0, "migrator receives no reward");

        // PRICE-SCALED: the target's rate was re-sized by `depositFor`'s tail
        // recompute against the grown `totalStaked`.
        assertGt(newStaker.rewardRate(), newRateBefore, "target rate re-sized on deposit");

        // Solvency holds on both sides.
        assertEq(
            phUSD.balanceOf(address(oldStaker)),
            oldStaker.rewardBudget() + oldStaker.committedDebt(),
            "old staker solvent"
        );
        assertEq(
            phUSD.balanceOf(address(newStaker)),
            newStaker.rewardBudget() + newStaker.committedDebt(),
            "new staker solvent"
        );
    }

    function testCrossStakerEmptyBatchShortCircuits() public {
        NFTStakerPriceScaledMigrateReady oldStaker = _newPriceScaled(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);
        phUSD.mint(address(oldStaker), 1 ether);

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        vm.prank(owner);
        newStaker.setMigrator(address(mig));
        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = stranger;
        vm.prank(owner);
        mig.migrate(u);
        assertEq(newStaker.totalStaked(), 0, "nothing credited on empty batch");
    }

    // ===================================================================
    // Cross-MODEL: Depletion -> PriceScaled through the same migrator
    // ===================================================================

    /// @dev `NFTStakerMigrator` holds `INFTStakerMigratable` on both sides with
    ///      no reference to either concrete staker, so a depletion-model source
    ///      and a price-scaled target compose without any migrator change.
    function testCrossModelDepletionToPriceScaled() public {
        NFTStakerDepletion oldStaker = _newDepletion(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);

        _stakeAs(address(oldStaker), alice, 5);
        _stakeAs(address(oldStaker), bob, 3);
        phUSD.mint(address(oldStaker), BUDGET);
        vm.prank(owner);
        oldStaker.setDepletionWindow(12);

        phUSD.mint(address(newStaker), BUDGET);
        vm.prank(owner);
        newStaker.setTargetAPY(TARGET_APY);

        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = oldStaker.pendingReward(alice);
        assertGt(alicePending, 0, "alice accrued under the depletion model");

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
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

        assertEq(oldStaker.totalStaked(), 0, "depletion staker drained");
        assertEq(newStaker.totalStaked(), 8, "price-scaled staker credited");
        (uint256 aNew,) = newStaker.userInfo(alice);
        assertEq(aNew, 5, "alice moved across models");
        assertEq(phUSD.balanceOf(alice), alicePending, "alice paid out of the depletion staker");

        // The target now emits under the price-scaled policy: an empty target
        // had rate 0, and the migrated-in stake gives it a live rate.
        assertGt(newStaker.rewardRate(), 0, "price-scaled rate live after cross-model migration");
        vm.warp(block.timestamp + 1 days);
        assertEq(newStaker.pendingReward(alice), newStaker.rewardRate() * 1 days * 5 / 8, "alice accrues pro rata");
    }

    // ===================================================================
    // In-place: unmodified InPlaceNFTStakerMigrator
    // ===================================================================

    function testInPlaceRoundTripWithDispatcherSwap() public {
        NFTStakerPriceScaledMigrateReady s = _newPriceScaled(ID);
        _stakeAs(address(s), alice, 5);
        _stakeAs(address(s), bob, 3);
        _fundPriceScaled(s);

        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = s.pendingReward(alice);
        assertGt(alicePending, 0, "alice accrued");

        InPlaceNFTStakerMigrator mig =
            new InPlaceNFTStakerMigrator(s, IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        s.setMigrator(address(mig));

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
        assertEq(phUSD.balanceOf(alice), alicePending, "reward paid at migrate-out");

        // SWAP: the empty-pool-gated rewire, only possible because the pool is
        // drained. `finalizeAndReset` first to flip back to Active.
        vm.prank(owner);
        s.finalizeAndReset();
        assertEq(s.rewardRate(), 0, "rate re-derived to zero on the empty pool");

        vm.prank(owner);
        s.setDispatcherIndex(ALT_DISPATCHER_INDEX);
        assertEq(s.dispatcherIndex(), ALT_DISPATCHER_INDEX, "dispatcher index swapped");

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

        // PRICE-SCALED: the rate is live again and sized against the NEW
        // dispatcher's price (250e6 vs 100e6) and the restored totalStaked.
        uint256 expected = (8 * (250e6 * PRICE_SCALE) * TARGET_APY / 1e18) / 365 days;
        assertEq(s.rewardRate(), expected, "rate re-derived against the swapped dispatcher");
        assertEq(
            phUSD.balanceOf(address(s)), s.rewardBudget() + s.committedDebt(), "solvency after in-place round trip"
        );
    }

    function testInPlaceClaimTimedOut() public {
        NFTStakerPriceScaledMigrateReady s = _newPriceScaled(ID);
        _stakeAs(address(s), alice, 5);
        _fundPriceScaled(s);

        InPlaceNFTStakerMigrator mig =
            new InPlaceNFTStakerMigrator(s, IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        s.setMigrator(address(mig));
        vm.prank(owner);
        mig.initiateMigration();
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(owner);
        mig.migrateOut(u);

        vm.expectRevert(bytes("InPlace: timeout not elapsed"));
        vm.prank(alice);
        mig.claimTimedOut();

        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.prank(alice);
        mig.claimTimedOut();
        assertEq(nft.balanceOf(alice, ID), 5, "alice reclaimed stake");
        assertEq(mig.totalParked(), 0, "parked cleared");
    }

    // ===================================================================
    // Wiring failure cases (silent by construction — assert they revert)
    // ===================================================================

    /// @dev The migrator must be set as `migrator` on BOTH stakers. If only the
    ///      source is wired, `initiateMigration` succeeds and the failure only
    ///      surfaces on the target's `depositFor`.
    function testCrossStakerRevertsWhenMigratorNotSetOnTarget() public {
        NFTStakerPriceScaledMigrateReady oldStaker = _newPriceScaled(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);
        _stakeAs(address(oldStaker), alice, 5);
        _fundPriceScaled(oldStaker);

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        // Deliberately NOT wired on `newStaker`.

        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert(bytes("NFTStaker: caller is not migrator"));
        vm.prank(owner);
        mig.migrate(u);
    }

    /// @dev Symmetric case: nothing is wired on the SOURCE, so
    ///      `initiateMigration` itself is rejected.
    function testCrossStakerRevertsWhenMigratorNotSetOnSource() public {
        NFTStakerPriceScaledMigrateReady oldStaker = _newPriceScaled(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);
        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);

        vm.expectRevert(bytes("NFTStaker: caller is not migrator"));
        vm.prank(owner);
        mig.initiateMigration();
    }

    /// @dev The target staker must be `Active`; a target left frozen from an
    ///      earlier migration rejects the redeposit.
    function testCrossStakerRevertsWhenTargetNotActive() public {
        NFTStakerPriceScaledMigrateReady oldStaker = _newPriceScaled(ID);
        NFTStakerPriceScaledMigrateReady newStaker = _newPriceScaled(ID);
        _stakeAs(address(oldStaker), alice, 5);
        _fundPriceScaled(oldStaker);

        // Freeze the target via a direct EOA migrator, then hand the role over.
        vm.prank(owner);
        newStaker.setMigrator(migrator);
        vm.prank(migrator);
        newStaker.initiateMigration();
        assertEq(uint256(newStaker.poolState()), 1, "target is Migrating");

        NFTStakerMigrator mig =
            new NFTStakerMigrator(oldStaker, newStaker, IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner);
        vm.prank(owner);
        oldStaker.setMigrator(address(mig));
        vm.prank(owner);
        newStaker.setMigrator(address(mig));

        vm.prank(owner);
        mig.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(owner);
        mig.migrate(u);
    }
}
