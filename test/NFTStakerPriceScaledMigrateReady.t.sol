// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {NFTStakerPriceScaledMigrateReady} from "../src/NFTStakerPriceScaledMigrateReady.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

/// @notice Staker-side migration primitive tests for
///         `NFTStakerPriceScaledMigrateReady`: `setMigrator`/`onlyMigrator`,
///         `initiateMigration` (settle+freeze), `batchMigrate` (settle+pay
///         reward to the USER, zero position, transfer ERC1155, idempotency),
///         permissionless `userMigrate`, `depositFor` (Active-only receive +
///         credit + TAIL RECOMPUTE), `finalizeAndReset` (post-reset rate
///         re-derivation), `rescueERC20`, and the two PriceScaled-specific
///         freeze deltas: `_syncBudget` must not recompute the schedule while
///         `Migrating`, and neither may the `stake` / `unstake` tails.
contract NFTStakerPriceScaledMigrateReadyTest is Test {
    NFTStakerPriceScaledMigrateReady internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal migrator = address(0x319A);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA01);
    address internal stranger = address(0xCAFE);
    address internal pauserAddr = address(0xBA05);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // Ratchet: 18dp phUSD reward, 6dp USDC prime -> 10 ** (18 - 6) = 1e12.
    uint256 internal constant PRICE_SCALE = 1e12;
    uint256 internal constant TARGET_APY = 0.45e18;
    uint256 internal constant BUDGET = 1_000_000 ether;

    event MigratorSet(address indexed previous, address indexed next);
    event MigrationInitiated(uint256 totalStaked);
    event MigratedOut(address indexed user, uint256 amount, uint256 reward);
    event UserMigrated(address indexed user, uint256 amount, uint256 reward);
    event DepositedFor(address indexed user, uint256 amount);
    event PoolReset();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        // Default config: price 100e6 (6dp USDC NEXT mint price), growthBP = 0.
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);

        staker = new NFTStakerPriceScaledMigrateReady(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            PRICE_SCALE
        );
        vm.prank(owner);
        staker.setMigrator(migrator);
        vm.prank(owner);
        staker.setPauser(pauserAddr);
    }

    // ----- helpers -----

    function _stakeAs(address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.prank(who);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(who);
        staker.stake(amount);
    }

    /// @dev Price-scaled analogue of the depletion suite's `_fundAndStart`.
    ///      NOTE: stakes must already exist for a non-zero rate, since
    ///      `S = totalStaked * latestPrice`.
    function _fundAndStart(uint256 budget) internal {
        phUSD.mint(address(staker), budget);
        vm.prank(owner);
        staker.setTargetAPY(TARGET_APY);
    }

    function _assertSolvent(string memory label) internal view {
        assertEq(phUSD.balanceOf(address(staker)), staker.rewardBudget() + staker.committedDebt(), label);
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
        _fundAndStart(BUDGET);
        assertGt(staker.rewardRate(), 0, "rate live before migration");

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
        assertEq(pendingAtFreeze, pendingBefore, "snapshot captured at freeze");
        vm.warp(block.timestamp + 30 days);
        assertEq(staker.pendingReward(alice), pendingAtFreeze, "pending frozen while migrating");
        assertEq(staker.totalDebt(), staker.committedDebt(), "totalDebt frozen at committedDebt");
    }

    function testInitiateMigrationRejectsNonActive() public {
        _stakeAs(alice, 1);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();
        vm.expectRevert(bytes("NFTStaker: not active"));
        vm.prank(migrator);
        staker.initiateMigration();
    }

    function testFrozenGapNotRetroAccruedAfterReset() public {
        _stakeAs(alice, 2);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();

        // Long frozen gap.
        vm.warp(block.timestamp + 30 days);

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);
        vm.prank(owner);
        staker.finalizeAndReset();

        // Pool is Active again: a fresh stake accrues from NOW, not from the
        // pre-freeze `lastRewardTime`.
        _stakeAs(bob, 4);
        uint256 rate = staker.rewardRate();
        assertGt(rate, 0, "rate live after reset");
        assertEq(staker.pendingReward(bob), 0, "no retro-accrual at stake time");
        vm.warp(block.timestamp + 1 days);
        assertEq(staker.pendingReward(bob), rate * 1 days, "accrual resumed post-reset");
    }

    // -------------------------------------------------------------------
    // PriceScaled-specific: the schedule must not be recomputed while frozen
    // -------------------------------------------------------------------

    function testSyncBudgetDoesNotRecomputeWhileMigrating() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();

        uint256 rate = staker.rewardRate();
        uint256 windowEnd = staker.windowEnd();
        uint256 budget = staker.rewardBudget();
        assertGt(rate, 0, "frozen snapshot has a live rate");

        // Grow V materially: a fresh phUSD balance AND pending hook mint debt.
        // An unguarded `_syncBudget` recompute would resize `rewardBudget` and
        // push `windowEnd` out from under the frozen snapshot.
        phUSD.mint(address(staker), 500_000 ether);
        MockBalancerPoolerMintDebtHook hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));
        hook.setPendingMint(250_000 ether);

        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        staker.pullAndRefresh();

        assertEq(staker.rewardRate(), rate, "rate pinned while migrating");
        assertEq(staker.windowEnd(), windowEnd, "windowEnd pinned while migrating");
        assertEq(staker.rewardBudget(), budget, "rewardBudget pinned while migrating");
    }

    function testStakeAndUnstakeDoNotRecomputeWhileMigrating() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();

        uint256 rate = staker.rewardRate();
        uint256 windowEnd = staker.windowEnd();

        // A stake while frozen still mutates `totalStaked` (the rate BASIS),
        // but must not re-size the frozen schedule.
        _stakeAs(bob, 10);
        assertEq(staker.totalStaked(), 15, "totalStaked mutated");
        assertEq(staker.rewardRate(), rate, "rate pinned across stake");
        assertEq(staker.windowEnd(), windowEnd, "windowEnd pinned across stake");

        vm.prank(bob);
        staker.unstake(10);
        assertEq(staker.totalStaked(), 5, "totalStaked restored");
        assertEq(staker.rewardRate(), rate, "rate pinned across unstake");
        assertEq(staker.windowEnd(), windowEnd, "windowEnd pinned across unstake");
    }

    // -------------------------------------------------------------------
    // batchMigrate — settle+pay reward, zero position, transfer ERC1155
    // -------------------------------------------------------------------

    function testBatchMigrateMovesStakeAndSettlesReward() public {
        _stakeAs(alice, 5);
        _stakeAs(bob, 3);
        _fundAndStart(BUDGET);

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

        // Pending phUSD reward paid to the USERS, never the migrator.
        assertEq(phUSD.balanceOf(alice), alicePending, "alice reward settled");
        assertEq(phUSD.balanceOf(bob), bobPending, "bob reward settled");
        assertEq(phUSD.balanceOf(migrator), 0, "migrator receives no reward");
    }

    function testBatchMigrateIdempotent() public {
        _stakeAs(alice, 4);
        _fundAndStart(BUDGET);
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
        _fundAndStart(BUDGET);
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.expectRevert(bytes("NFTStaker: not migrating"));
        vm.prank(migrator);
        staker.batchMigrate(u);
    }

    // -------------------------------------------------------------------
    // userMigrate — permissionless self-exit
    // -------------------------------------------------------------------

    function testUserMigrateSelfExit() public {
        _stakeAs(alice, 6);
        _fundAndStart(BUDGET);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = staker.pendingReward(alice);

        vm.prank(migrator);
        staker.initiateMigration();

        vm.expectEmit(true, false, false, true, address(staker));
        emit UserMigrated(alice, 6, pending);
        vm.prank(alice);
        staker.userMigrate();

        assertEq(nft.balanceOf(alice, ID), 6, "stake returned to wallet");
        assertEq(phUSD.balanceOf(alice), pending, "reward settled");
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 0, "position zeroed");
        assertEq(staker.totalStaked(), 0, "totalStaked decremented");
    }

    function testUserMigrateRequiresMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(BUDGET);
        vm.expectRevert(bytes("NFTStaker: not migrating"));
        vm.prank(alice);
        staker.userMigrate();
    }

    function testUserMigrateRequiresPosition() public {
        _stakeAs(alice, 1);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();
        vm.expectRevert(bytes("NFTStaker: nothing staked"));
        vm.prank(stranger);
        staker.userMigrate();
    }

    // -------------------------------------------------------------------
    // depositFor — Active-only receive + credit + TAIL RECOMPUTE
    // -------------------------------------------------------------------

    function testDepositForCreditsUser() public {
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

    function testDepositForSettlesExistingPending() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.warp(block.timestamp + 1 days);
        uint256 pending = staker.pendingReward(alice);
        assertGt(pending, 0, "alice has pending");

        nft.mint(migrator, ID, 2);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(migrator);
        staker.depositFor(alice, 2);

        // Paid to the USER, not to `msg.sender` (the migrator).
        assertEq(phUSD.balanceOf(alice), pending, "existing pending settled to alice");
        assertEq(phUSD.balanceOf(migrator), 0, "migrator receives no reward on depositFor");
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 7, "credited on top of existing position");
        assertEq(staker.pendingReward(alice), 0, "pending cleared");
        _assertSolvent("solvency after depositFor");
    }

    /// @dev THE delta that distinguishes this contract from
    ///      `NFTStakerDepletion`: `R = totalStaked * latestPrice * targetAPY /
    ///      SECONDS_PER_YEAR`, so a `depositFor` that grows `totalStaked` must
    ///      grow the rate. Without the tail `_recomputeSchedule` the migrated-in
    ///      users would emit at the pre-deposit rate.
    function testDepositForRecomputesRate() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        uint256 rateBefore = staker.rewardRate();
        assertGt(rateBefore, 0, "rate live before deposit");

        nft.mint(migrator, ID, 5);
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(migrator);
        staker.depositFor(bob, 5);

        uint256 rateAfter = staker.rewardRate();
        assertEq(staker.totalStaked(), 10, "totalStaked doubled");
        assertGt(rateAfter, rateBefore, "rate rose with totalStaked");
        // Doubling `totalStaked` doubles S and therefore R (floor dust aside).
        assertApproxEqAbs(rateAfter, rateBefore * 2, 1, "rate scales linearly with totalStaked");
    }

    function testDepositForBlockedWhileMigrating() public {
        _stakeAs(alice, 1);
        _fundAndStart(BUDGET);
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

    // -------------------------------------------------------------------
    // finalizeAndReset — Migrating -> Active when empty
    // -------------------------------------------------------------------

    function testFinalizeAndResetReturnsToActive() public {
        _stakeAs(alice, 2);
        _fundAndStart(BUDGET);
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
        _fundAndStart(BUDGET);
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

    /// @dev PriceScaled-specific delta 3. The pre-migration rate was sized
    ///      against the pre-migration `totalStaked`; after the drain the pool
    ///      is empty, so `S == 0` and the re-derived rate must be 0 with
    ///      `windowEnd == now` — exactly the state an `unstake` down to zero
    ///      leaves behind. `rewardBudget` is re-sized to `V - committedDebt`.
    function testFinalizeAndResetReDerivesRate() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.warp(block.timestamp + 1 days);
        vm.prank(migrator);
        staker.initiateMigration();
        assertGt(staker.rewardRate(), 0, "frozen rate is non-zero");

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);

        vm.prank(owner);
        staker.finalizeAndReset();

        assertEq(staker.rewardRate(), 0, "rate re-derived to zero on an empty pool");
        assertEq(staker.windowEnd(), block.timestamp, "windowEnd == now on an empty pool");
        assertEq(staker.lastRewardTime(), block.timestamp, "lastRewardTime fast-forwarded");
        _assertSolvent("solvency after finalizeAndReset");
    }

    /// @dev Cross-check: the post-reset state is identical to what an
    ///      `unstake`-to-zero produces on the same contract.
    function testFinalizeAndResetMatchesUnstakeToZero() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staker.unstake(5);

        uint256 rateAfterUnstake = staker.rewardRate();
        uint256 windowAfterUnstake = staker.windowEnd();

        assertEq(rateAfterUnstake, 0, "unstake-to-zero zeroes the rate");
        assertEq(windowAfterUnstake, block.timestamp, "unstake-to-zero pins windowEnd to now");
    }

    // -------------------------------------------------------------------
    // Paused behaviour — batchMigrate / depositFor stay callable
    // -------------------------------------------------------------------

    function testMigrationPrimitivesWorkWhilePaused() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.prank(migrator);
        staker.initiateMigration();

        vm.prank(pauserAddr);
        staker.pause();
        assertTrue(staker.paused(), "paused");

        // batchMigrate still drains while paused.
        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);
        assertEq(nft.balanceOf(migrator, ID), 5, "drained while paused");

        // Reset + depositFor also work while paused.
        vm.prank(owner);
        staker.finalizeAndReset();
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(migrator);
        staker.depositFor(carol, 5);
        (uint256 amt,) = staker.userInfo(carol);
        assertEq(amt, 5, "depositFor credited while paused");

        // Regular staking is still blocked while paused.
        nft.mint(bob, ID, 1);
        vm.prank(bob);
        nft.setApprovalForAll(address(staker), true);
        vm.expectRevert();
        vm.prank(bob);
        staker.stake(1);
    }

    // -------------------------------------------------------------------
    // Solvency across the full cycle
    // -------------------------------------------------------------------

    function testSolvencyAcrossFullMigrationCycle() public {
        _stakeAs(alice, 5);
        _stakeAs(bob, 3);
        _fundAndStart(BUDGET);
        _assertSolvent("solvency after funding");

        vm.warp(block.timestamp + 3 days);
        vm.prank(migrator);
        staker.initiateMigration();
        _assertSolvent("solvency after initiateMigration");

        address[] memory u = new address[](1);
        u[0] = alice;
        vm.prank(migrator);
        staker.batchMigrate(u);
        _assertSolvent("solvency after batchMigrate");

        vm.prank(bob);
        staker.userMigrate();
        _assertSolvent("solvency after userMigrate");

        vm.prank(owner);
        staker.finalizeAndReset();
        _assertSolvent("solvency after finalizeAndReset");

        // Re-inject and keep accruing.
        vm.prank(migrator);
        nft.setApprovalForAll(address(staker), true);
        vm.prank(migrator);
        staker.depositFor(alice, 5);
        _assertSolvent("solvency after depositFor");

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        staker.claim();
        _assertSolvent("solvency after post-migration claim");
    }

    // -------------------------------------------------------------------
    // rescueERC20
    // -------------------------------------------------------------------

    function testRescueERC20SweepsNonRewardToken() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1_000 ether);

        vm.expectEmit(true, true, false, true, address(staker));
        emit Rescued(address(other), bob, 1_000 ether);
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(other)), bob, 1_000 ether);
        assertEq(other.balanceOf(bob), 1_000 ether, "non-reward token swept");
    }

    function testRescueERC20OnlyOwnerAndNonZeroRecipient() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(staker), 1 ether);

        vm.expectRevert();
        vm.prank(stranger);
        staker.rescueERC20(IERC20(address(other)), bob, 1 ether);

        vm.expectRevert(NFTStakerPriceScaledMigrateReady.Rescue__ZeroRecipient.selector);
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(other)), address(0), 1 ether);
    }

    function testRescueERC20CannotDrainCommittedDebt() public {
        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);
        vm.warp(block.timestamp + 10 days);

        // Settle so `committedDebt` is non-zero, then try to rescue everything.
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 committed = staker.committedDebt();
        assertGt(committed, 0, "committedDebt accrued");

        uint256 heldBalance = phUSD.balanceOf(address(staker));
        vm.expectRevert(bytes("NFTStaker: rescue breaches committedDebt"));
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(phUSD)), bob, heldBalance);

        // Rescuing genuine surplus succeeds and keeps the invariant.
        uint256 surplus = heldBalance - committed;
        vm.prank(owner);
        staker.rescueERC20(IERC20(address(phUSD)), bob, surplus);
        assertEq(phUSD.balanceOf(bob), surplus, "surplus rescued");
        _assertSolvent("solvency after rescue");
        assertGe(phUSD.balanceOf(address(staker)), staker.committedDebt(), "committed debt still covered");
    }

    // -------------------------------------------------------------------
    // PriceScaled semantics unchanged
    // -------------------------------------------------------------------

    function testPriceScaleAndTargetAPYSemanticsUnchanged() public {
        assertEq(staker.priceScale(), PRICE_SCALE, "priceScale immutable preserved");
        assertEq(staker.MAX_TARGET_APY(), 0.5e18, "MAX_TARGET_APY preserved");

        vm.expectRevert(bytes("NFTStaker: APY too high"));
        vm.prank(owner);
        staker.setTargetAPY(0.5e18 + 1);

        _stakeAs(alice, 5);
        _fundAndStart(BUDGET);

        // R == totalStaked * (price * priceScale) * A / SECONDS_PER_YEAR.
        uint256 latestPrice = 100e6 * PRICE_SCALE;
        uint256 expected = (5 * latestPrice * TARGET_APY / 1e18) / SECONDS_PER_YEAR;
        assertEq(staker.rewardRate(), expected, "price-scaled closed-form rate preserved");
    }

    function testConstructorRejectsZeroPriceScale() public {
        vm.expectRevert(bytes("NFTStaker: zero price scale"));
        new NFTStakerPriceScaledMigrateReady(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            0
        );
    }
}
