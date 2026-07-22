// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerDepletionV2} from "../src/NFTStakerDepletionV2.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";

/// @notice Staker-side migration primitive tests for `NFTStakerDepletionV2`
///         (story-026 mirror of `test/NFTStakerDepletionMigration.t.sol`):
///         `setMigrator`/`onlyMigrator`, `initiateMigration` (settle+freeze),
///         `batchMigrate` (settle+mint reward, zero position, transfer ERC1155,
///         idempotency), `depositFor` (Active-only receive + credit),
///         permissionless `userMigrate`, `finalizeAndReset`, and the
///         Migrating-state freeze of `_updatePool`.
///
///         V2 DELTA (audit-21 M-03): unlike the frozen V1, `depositFor` onto a
///         pre-existing position settles the pending reward to the USER via
///         `_safePayTo(user, pending)`. The V1 buggy-behaviour expectation
///         (run-20 PoC `testA_DepositForPaysMigratorNotUser`: pending paid to
///         the migrator) is INVERTED here —
///         `testDepositForSettlesExistingPendingToUser` asserts the user's
///         balance grows by the exact pending, the migrator's balance is
///         unchanged, and `Claimed(user, pending)` is truthful. The
///         `whenNotPaused`-exemption on `depositFor` is covered too.
contract NFTStakerDepletionV2MigrationTest is Test {
    NFTStakerDepletionV2 internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal migrator = address(0x319A);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0xCAFE);
    address internal pauserAddr = address(0xBA5E);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_MONTH = 365 days / 12;

    event Claimed(address indexed user, uint256 amount);
    event MigratorSet(address indexed previous, address indexed next);
    event MigrationInitiated(uint256 totalStaked);
    event MigratedOut(address indexed user, uint256 amount, uint256 reward);
    event UserMigrated(address indexed user, uint256 amount, uint256 reward);
    event DepositedFor(address indexed user, uint256 amount);
    event PoolReset();

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);

        staker = new NFTStakerDepletionV2(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
        vm.prank(owner);
        staker.setMigrator(migrator);
    }

    // ----- helpers -----

    function _stakeAs(address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.prank(who);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(who);
        staker.stake(amount);
    }

    function _fundAndStart(uint256 budget, uint256 months) internal {
        phUSD.mint(address(staker), budget);
        vm.prank(owner);
        staker.setDepletionWindow(months);
    }

    // -------------------------------------------------------------------
    // setMigrator / onlyMigrator
    // -------------------------------------------------------------------

    function testSetMigratorOnlyOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        staker.setMigrator(stranger);
    }

    function testSetMigratorEmitsAndSets() public {
        vm.expectEmit(true, true, false, false, address(staker));
        emit MigratorSet(migrator, bob);
        vm.prank(owner);
        staker.setMigrator(bob);
        assertEq(staker.migrator(), bob, "migrator updated");
    }

    function testInitiateMigrationOnlyMigrator() public {
        vm.expectRevert(bytes("NFTStaker: caller is not migrator"));
        vm.prank(stranger);
        staker.initiateMigration();
    }

    function testBatchMigrateOnlyMigrator() public {
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert(bytes("NFTStaker: caller is not migrator"));
        vm.prank(stranger);
        staker.batchMigrate(u);
    }

    function testDepositForOnlyMigrator() public {
        vm.expectRevert(bytes("NFTStaker: caller is not migrator"));
        vm.prank(stranger);
        staker.depositFor(alice, 1);
    }

    function testFinalizeAndResetOnlyOwner() public {
        vm.expectRevert();
        vm.prank(stranger);
        staker.finalizeAndReset();
    }

    // -------------------------------------------------------------------
    // initiateMigration — settle + freeze
    // -------------------------------------------------------------------

    function testInitiateMigrationFreezesPool() public {
        _stakeAs(alice, 5);
        _fundAndStart(1_000_000 ether, 12);

        vm.warp(block.timestamp + 1 days);
        uint256 pendingBefore = staker.pendingReward(alice);
        assertGt(pendingBefore, 0, "expected accrual");

        vm.expectEmit(false, false, false, true, address(staker));
        emit MigrationInitiated(5);
        vm.prank(migrator);
        staker.initiateMigration();

        assertEq(uint256(staker.poolState()), 1, "poolState == Migrating");

        // Emissions are now frozen: warping further does not increase pending.
        uint256 pendingAtFreeze = staker.pendingReward(alice);
        vm.warp(block.timestamp + 30 days);
        assertEq(staker.pendingReward(alice), pendingAtFreeze, "pending frozen while migrating");
    }

    function testInitiateMigrationRejectsNonActive() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(migrator);
        staker.initiateMigration();
    }

    // -------------------------------------------------------------------
    // batchMigrate — settle+mint reward, zero position, transfer ERC1155
    // -------------------------------------------------------------------

    function testBatchMigrateMovesStakeAndSettlesReward() public {
        _stakeAs(alice, 5);
        _stakeAs(bob, 3);
        _fundAndStart(1_000_000 ether, 12);

        vm.warp(block.timestamp + 1 days);
        uint256 alicePending = staker.pendingReward(alice);
        uint256 bobPending = staker.pendingReward(bob);
        assertGt(alicePending, 0, "alice pending");

        vm.prank(migrator);
        staker.initiateMigration();

        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = bob;
        vm.prank(migrator);
        uint256[] memory amts = staker.batchMigrate(u);

        assertEq(amts[0], 5, "alice staked amount returned");
        assertEq(amts[1], 3, "bob staked amount returned");

        // ERC1155 moved to the migrator.
        assertEq(nft.balanceOf(migrator, ID), 8, "migrator holds parked stake");
        assertEq(nft.balanceOf(address(staker), ID), 0, "staker drained");

        // Positions zeroed.
        (uint256 aAmt,) = staker.userInfo(alice);
        (uint256 bAmt,) = staker.userInfo(bob);
        assertEq(aAmt, 0, "alice zeroed");
        assertEq(bAmt, 0, "bob zeroed");
        assertEq(staker.totalStaked(), 0, "totalStaked zeroed");

        // Pending phUSD reward minted to the users (not the migrator).
        assertEq(phUSD.balanceOf(alice), alicePending, "alice reward settled");
        assertEq(phUSD.balanceOf(bob), bobPending, "bob reward settled");
        assertEq(phUSD.balanceOf(migrator), 0, "migrator receives no reward");
    }

    function testBatchMigrateIdempotent() public {
        _stakeAs(alice, 4);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        uint256[] memory first = staker.batchMigrate(u);
        assertEq(first[0], 4, "first run moves stake");

        // Re-run: already-zeroed user returns 0, no extra transfer.
        vm.prank(migrator);
        uint256[] memory second = staker.batchMigrate(u);
        assertEq(second[0], 0, "idempotent re-run returns 0");
        assertEq(nft.balanceOf(migrator, ID), 4, "no double transfer");
    }

    function testBatchMigrateRequiresMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert(bytes("NFTStaker: not migrating"));
        vm.prank(migrator);
        staker.batchMigrate(u);
    }

    function testBatchMigrateSolvencyInvariant() public {
        _stakeAs(alice, 5);
        _fundAndStart(1_000_000 ether, 12);
        vm.warp(block.timestamp + 2 days);
        vm.prank(migrator);
        staker.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);

        // balance == rewardBudget + committedDebt still holds.
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "solvency invariant after batchMigrate"
        );
    }

    // -------------------------------------------------------------------
    // userMigrate — permissionless self-exit
    // -------------------------------------------------------------------

    function testUserMigrateSelfExit() public {
        _stakeAs(alice, 6);
        _fundAndStart(1_000_000 ether, 12);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = staker.pendingReward(alice);

        vm.prank(migrator);
        staker.initiateMigration();

        vm.expectEmit(true, false, false, true, address(staker));
        emit UserMigrated(alice, 6, pending);
        vm.prank(alice);
        staker.userMigrate();

        // Stake back to alice's wallet, reward settled, position zeroed.
        assertEq(nft.balanceOf(alice, ID), 6, "stake returned to wallet");
        assertEq(phUSD.balanceOf(alice), pending, "reward settled");
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 0, "position zeroed");
        assertEq(staker.totalStaked(), 0, "totalStaked decremented");
    }

    function testUserMigrateRequiresMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        vm.expectRevert(bytes("NFTStaker: not migrating"));
        vm.prank(alice);
        staker.userMigrate();
    }

    function testUserMigrateRequiresPosition() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();
        vm.expectRevert(bytes("NFTStaker: nothing staked"));
        vm.prank(stranger);
        staker.userMigrate();
    }

    // -------------------------------------------------------------------
    // depositFor — Active-only receive + credit
    // -------------------------------------------------------------------

    function testDepositForCreditsUser() public {
        // Migrator holds ERC1155 to deposit on alice's behalf.
        nft.mint(migrator, ID, 7);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);

        vm.expectEmit(true, false, false, true, address(staker));
        emit DepositedFor(alice, 7);
        vm.prank(migrator);
        staker.depositFor(alice, 7);

        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 7, "alice credited");
        assertEq(staker.totalStaked(), 7, "totalStaked increased");
        assertEq(nft.balanceOf(address(staker), ID), 7, "staker holds stake");
    }

    function testDepositForBlockedWhileMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();

        nft.mint(migrator, ID, 3);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(migrator);
        staker.depositFor(bob, 3);
    }

    function testDepositForRejectsZero() public {
        vm.expectRevert(bytes("NFTStaker: zero deposit"));
        vm.prank(migrator);
        staker.depositFor(alice, 0);
    }

    /// @dev THE story-026 fix assertion (audit-21 M-03; INVERTS the run-20 PoC
    ///      `testA_DepositForPaysMigratorNotUser`): a `depositFor` onto a
    ///      pre-existing position settles that position's pending reward to
    ///      the USER — not to `msg.sender` (the migrator) — and the
    ///      `Claimed(user, pending)` event is truthful.
    function testDepositForSettlesExistingPendingToUser() public {
        _stakeAs(alice, 5);
        _fundAndStart(1_000_000 ether, 12);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0, "alice has pending");

        nft.mint(migrator, ID, 2);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);

        uint256 aliceBefore = phUSD.balanceOf(alice);
        uint256 migratorBefore = phUSD.balanceOf(migrator);

        vm.expectEmit(true, false, false, true, address(staker));
        emit Claimed(alice, pending);
        vm.prank(migrator);
        staker.depositFor(alice, 2);

        // Paid to the USER, not to `msg.sender` (the migrator).
        assertEq(phUSD.balanceOf(alice) - aliceBefore, pending, "existing pending settled to alice");
        assertEq(phUSD.balanceOf(migrator), migratorBefore, "migrator balance unchanged");
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 7, "credited on top of existing position");
        assertEq(staker.pendingReward(alice), 0, "pending cleared");
        // Solvency invariant preserved through the fixed settlement path.
        assertEq(
            phUSD.balanceOf(address(staker)),
            staker.rewardBudget() + staker.committedDebt(),
            "solvency after depositFor"
        );
    }

    /// @dev `depositFor` is deliberately `whenNotPaused`-exempt so a freshly
    ///      deployed (and possibly paused) target can be seeded — preserved
    ///      from V1.
    function testDepositForWorksWhilePaused() public {
        vm.prank(owner);
        staker.setPauser(pauserAddr);
        vm.prank(pauserAddr);
        staker.pause();
        assertTrue(staker.paused(), "paused");

        nft.mint(migrator, ID, 3);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(migrator);
        staker.depositFor(alice, 3);
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 3, "depositFor credited while paused");

        // Regular staking stays blocked while paused.
        nft.mint(bob, ID, 1);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert();
        vm.prank(bob);
        staker.stake(1);
    }

    // -------------------------------------------------------------------
    // stake — Active-only (audit-20 M-05); unstake / claim stay ungated
    // -------------------------------------------------------------------

    function testStakeBlockedWhileMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();

        nft.mint(bob, ID, 3);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(bob);
        staker.stake(3);
    }

    /// @dev M-05 bounds the harm to `stake`: `unstake` and `claim` settle
    ///      against the frozen `accRewardPerShare` and are benign — and
    ///      unstake-while-Migrating is load-bearing (it is how `totalStaked`
    ///      drains to 0 so `finalizeAndReset` becomes reachable).
    function testUnstakeAndClaimStillCallableWhileMigrating() public {
        _stakeAs(alice, 5);
        _stakeAs(bob, 3);
        _fundAndStart(1_000_000 ether, 12);
        vm.warp(block.timestamp + 1 days);
        vm.prank(migrator);
        staker.initiateMigration();

        // claim pays out the frozen pending.
        uint256 alicePending = staker.pendingReward(alice);
        assertGt(alicePending, 0, "alice has frozen pending");
        vm.prank(alice);
        staker.claim();
        assertEq(phUSD.balanceOf(alice), alicePending, "claim paid frozen pending");
        assertEq(staker.pendingReward(alice), 0, "pending cleared");

        // unstake returns principal and drains totalStaked toward 0.
        vm.prank(bob);
        staker.unstake(3);
        assertEq(nft.balanceOf(bob, ID), 3, "bob principal returned");
        assertEq(staker.totalStaked(), 5, "totalStaked drained by bob's unstake");

        vm.prank(alice);
        staker.unstake(5);
        assertEq(staker.totalStaked(), 0, "fully drained while Migrating");
    }

    /// @dev Audit-20 M-05 availability leg (inverse of the run-20 PoC
    ///      `testGrieferBlocksFinalizeAndReset`): a griefer's permissionless
    ///      stake during `Migrating` reverts, so `totalStaked` can still be
    ///      drained to 0, `finalizeAndReset` stays reachable, and staking
    ///      resumes once the pool is `Active` again.
    function testGrieferCannotWedgeFinalizeAndReset() public {
        _stakeAs(alice, 2);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();

        // The would-be griefer's stake reverts instead of wedging the pool.
        nft.mint(stranger, ID, 1);
        vm.prank(stranger);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(stranger);
        staker.stake(1);

        // Drain every existing stake so the pool empties.
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);
        assertEq(staker.totalStaked(), 0, "drained to zero despite griefer attempt");

        // finalizeAndReset is NOT wedged.
        vm.prank(owner);
        staker.finalizeAndReset();
        assertEq(uint256(staker.poolState()), 0, "back to Active");

        // Staking works again after the reset.
        vm.prank(stranger);
        staker.stake(1);
        assertEq(staker.totalStaked(), 1, "stake accepted once Active again");
    }

    // -------------------------------------------------------------------
    // finalizeAndReset — Migrating -> Active when empty
    // -------------------------------------------------------------------

    function testFinalizeAndResetReturnsToActive() public {
        _stakeAs(alice, 2);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);

        assertEq(staker.totalStaked(), 0, "drained");
        vm.expectEmit(false, false, false, false, address(staker));
        emit PoolReset();
        vm.prank(owner);
        staker.finalizeAndReset();
        assertEq(uint256(staker.poolState()), 0, "back to Active");
    }

    function testFinalizeAndResetRequiresEmpty() public {
        _stakeAs(alice, 2);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();
        // Did NOT drain alice.
        vm.expectRevert(bytes("NFTStaker: stake outstanding"));
        vm.prank(owner);
        staker.finalizeAndReset();
    }

    function testFinalizeAndResetRequiresMigrating() public {
        vm.expectRevert(bytes("NFTStaker: not migrating"));
        vm.prank(owner);
        staker.finalizeAndReset();
    }

    function testResetAllowsRestakeAndAccrual() public {
        _stakeAs(alice, 2);
        _fundAndStart(1_000_000 ether, 12);
        vm.prank(migrator);
        staker.initiateMigration();
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);
        vm.prank(owner);
        staker.finalizeAndReset();

        // Pool is Active again: a fresh stake accrues normally.
        _stakeAs(bob, 4);
        vm.prank(owner);
        staker.setDepletionWindow(12);
        uint256 rate = staker.rewardRate();
        assertGt(rate, 0, "rate live after reset");
        vm.warp(block.timestamp + 1 days);
        assertEq(staker.pendingReward(bob), rate * 1 days, "accrual resumed post-reset");
    }
}
