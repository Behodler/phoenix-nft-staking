// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {NFTStakerDepletion} from "../src/NFTStakerDepletion.sol";
import {NFTStakerDepletionV2} from "../src/NFTStakerDepletionV2.sol";
import {NFTStakerPriceScaledMigrateReady} from "../src/NFTStakerPriceScaledMigrateReady.sol";
import {NFTStakerMigrator} from "../src/NFTStakerMigrator.sol";
import {InPlaceNFTStakerMigrator} from "../src/InPlaceNFTStakerMigrator.sol";
import {INFTStakerMigratable} from "../src/INFTStakerMigratable.sol";
import {INFTSupply} from "../src/INFTSupply.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNFTMinter} from "./mocks/MockNFTMinter.sol";
import {MockUniboostMintDebtHook} from "./mocks/MockUniboostMintDebtHook.sol";

/// @notice A phUSD-shaped ERC20 that can blocklist a single `(from, to)` edge
///         (USDC-style). Lifted from the audit PoC
///         (`PoC_Drift01_MigratorSidePatch.t.sol`) so the migrator -> user
///         forwarding leg can be made to REVERT while every staker -> user leg
///         still succeeds. That isolates the liveness cost of the forwarding
///         patch itself.
contract BlocklistERC20 is ERC20 {
    address public blockedFrom;
    address public blockedTo;

    constructor() ERC20("phUSD", "phUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedEdge(address from_, address to_) external {
        blockedFrom = from_;
        blockedTo = to_;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!(from == blockedFrom && to == blockedTo && blockedTo != address(0)), "BlocklistERC20: edge blocked");
        super._update(from, to, value);
    }
}

/// @notice A phUSD-shaped ERC20 that returns `false` (WITHOUT reverting) on a
///         single blocked `(from, to)` edge. Exercises the OTHER escrow branch:
///         the `try ... returns (bool ok)` / `ok == false` path, which a bare
///         `safeTransfer` could not distinguish.
contract FalseReturningERC20 is ERC20 {
    address public blockedFrom;
    address public blockedTo;

    constructor() ERC20("phUSD", "phUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedEdge(address from_, address to_) external {
        blockedFrom = from_;
        blockedTo = to_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (msg.sender == blockedFrom && to == blockedTo && blockedTo != address(0)) {
            return false;
        }
        return super.transfer(to, value);
    }
}

/// @notice Settlement-capture forwarding suite for both migrator orchestrators
///         (audit finding `pns20h1` / DRIFT-01, run `phoenix-nft-staking-20`).
///
///         `NFTStakerDepletion.depositFor` settles the incoming user's pending
///         phUSD with `_safePay(pending)` (`src/NFTStakerDepletion.sol:756`),
///         which pays `msg.sender` — always the migrator — instead of the user.
///         That staker is DEPLOYED and IMMUTABLE, so the fix lands on the
///         migrator: measure the reward-token balance delta across every
///         `depositFor`, bound it by the pre-call `pendingReward`, and forward
///         it to the user it belonged to.
///
///         `NFTStakerPriceScaledMigrateReady.depositFor` already settles
///         correctly via `_safePayTo(user, pending)` (:887), so the measured
///         capture there is ZERO and the branch self-disables. That is what
///         makes one migrator codebase version-agnostic across every staker
///         exposing `depositFor` — see `testVersionAgnosticPair...` below.
///
///         Test IDs A..H mirror the audit PoC
///         (`workspace/phoenix-nft-staking/test/PoC_Drift01_MigratorSidePatch.t.sol`,
///         9/9 at `0d1a0b2`). `E2` and `G` documented HOLES in the proved
///         baseline and are INVERTED here by the two mechanisms this story adds
///         on top of it: the `require(captured <= owed)` bound and
///         escrow-on-failure.
contract MigratorRewardForwardingTest is Test {
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockNFTMinter internal nftMinter;

    address internal owner = address(0xD1);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    uint256 internal constant ID = 1;
    uint256 internal constant DISPATCHER_INDEX = 1;
    uint256 internal constant BUDGET = 1_000_000 ether;
    uint256 internal constant PRICE_SCALE = 1e12;
    uint256 internal constant TARGET_APY = 0.45e18;
    uint256 internal constant TIMEOUT = 7 days;

    bytes32 internal constant REWARD_FORWARDED_SIG = keccak256("RewardForwarded(address,uint256)");

    event RewardForwarded(address indexed user, uint256 amount);
    event RewardForwardFailed(address indexed user, uint256 amount);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        nftMinter = new MockNFTMinter();
        nftMinter.setConfig(DISPATCHER_INDEX, address(0xBEEF), 100e6, 0, false);
        nftMinter.setTotalSupply(ID, 0);
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    function _newDepletion() internal returns (NFTStakerDepletion s) {
        return _newDepletionWithToken(IERC20(address(phUSD)));
    }

    function _newDepletionWithToken(IERC20 token) internal returns (NFTStakerDepletion s) {
        s = new NFTStakerDepletion(
            IERC1155(address(nft)), ID, token, owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(s), BUDGET));
        require(ok, "mint failed");
        vm.prank(owner);
        s.setDepletionWindow(12);
    }

    /// @dev Story-026 fixture: `NFTStakerDepletionV2` shares V1's constructor
    ///      signature exactly, but settles `depositFor` pending to the USER
    ///      via `_safePayTo(user, ...)` (audit-21 M-03 fix).
    function _newDepletionV2() internal returns (NFTStakerDepletionV2 s) {
        s = new NFTStakerDepletionV2(
            IERC1155(address(nft)), ID, IERC20(address(phUSD)), owner, INFTSupply(address(nftMinter)), DISPATCHER_INDEX
        );
        phUSD.mint(address(s), BUDGET);
        vm.prank(owner);
        s.setDepletionWindow(12);
    }

    /// @dev `NFTStakerPriceScaledMigrateReady`'s constructor takes a trailing
    ///      `PRICE_SCALE` arg that `NFTStakerDepletion`'s does not.
    function _newPriceScaled() internal returns (NFTStakerPriceScaledMigrateReady s) {
        s = new NFTStakerPriceScaledMigrateReady(
            IERC1155(address(nft)),
            ID,
            IERC20(address(phUSD)),
            owner,
            INFTSupply(address(nftMinter)),
            DISPATCHER_INDEX,
            PRICE_SCALE
        );
        phUSD.mint(address(s), BUDGET);
        vm.prank(owner);
        s.setTargetAPY(TARGET_APY);
    }

    function _stakeAs(address stakerAddr, address who, uint256 amount) internal {
        nft.mint(who, ID, amount);
        vm.startPrank(who);
        nft.setApprovalForAll(stakerAddr, true);
        (bool ok,) = stakerAddr.call(abi.encodeWithSignature("stake(uint256)", amount));
        require(ok, "stake failed");
        vm.stopPrank();
    }

    function _newCrossMigrator(address oldStaker, address newStaker, IERC20 token)
        internal
        returns (NFTStakerMigrator mig)
    {
        mig = new NFTStakerMigrator(
            INFTStakerMigratable(oldStaker), INFTStakerMigratable(newStaker), IERC1155(address(nft)), ID, token, owner
        );
        vm.startPrank(owner);
        (bool a,) = oldStaker.call(abi.encodeWithSignature("setMigrator(address)", address(mig)));
        (bool b,) = newStaker.call(abi.encodeWithSignature("setMigrator(address)", address(mig)));
        vm.stopPrank();
        require(a && b, "setMigrator failed");
    }

    function _one(address u) internal pure returns (address[] memory us) {
        us = new address[](1);
        us[0] = u;
    }

    function _countForwardEvents(Vm.Log[] memory logs, address emitter) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == REWARD_FORWARDED_SIG) {
                n++;
            }
        }
    }

    // ==================================================================
    // A. CONTROL — the patched migrator does NOT strand the reward.
    //
    //    REGRESSION ANCHOR: at commit 0d1a0b2 the UNPATCHED
    //    `NFTStakerMigrator` stranded 100% of the target-staker settlement —
    //    82,191.78 phUSD in the audit PoC's `testA` fixture, permanently, as
    //    the contract had no `rescueERC20`, no `rescueERC1155`, no `receive`
    //    and no `fallback`. That stranding is what this suite asserts is gone.
    // ==================================================================
    function testA_Control_PatchedMigratorDoesNotStrand() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        uint256 pendingOnNew = newStaker.pendingReward(alice);
        assertGt(pendingOnNew, 0, "alice accrued on the target staker");

        uint256 aliceBefore = phUSD.balanceOf(alice);
        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(phUSD.balanceOf(address(mig)), 0, "PATCH: nothing stranded (unpatched stranded 100%)");
        assertGe(phUSD.balanceOf(alice) - aliceBefore, pendingOnNew, "alice received the target-staker settlement");
        assertEq(mig.totalUnforwarded(), 0, "nothing escrowed on the happy path");
    }

    // ==================================================================
    // B. Cross-staker: exact pending across BOTH legs, residual 0.
    // ==================================================================
    function testB_CrossStakerDeliversExactPending() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        uint256 pendingOnOld = oldStaker.pendingReward(alice);
        uint256 pendingOnNew = newStaker.pendingReward(alice);
        assertGt(pendingOnNew, 0, "alice accrued on the target staker");

        uint256 aliceBefore = phUSD.balanceOf(alice);

        vm.startPrank(owner);
        mig.initiateMigration();
        vm.expectEmit(true, false, false, true, address(mig));
        emit RewardForwarded(alice, pendingOnNew);
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(phUSD.balanceOf(alice) - aliceBefore, pendingOnOld + pendingOnNew, "alice paid BOTH legs exactly");
        assertEq(phUSD.balanceOf(address(mig)), 0, "nothing left in the migrator");
        (uint256 amt,) = newStaker.userInfo(alice);
        assertEq(amt, 14, "stake credited (4 pre-existing + 10 migrated)");
    }

    // ==================================================================
    // C. In-place `migrateIn`: exact pending delivered, residual 0.
    // ==================================================================
    function testC_InPlaceMigrateInDeliversExactPending() public {
        NFTStakerDepletion staker = _newDepletion();
        InPlaceNFTStakerMigrator mig = new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(staker)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner
        );
        vm.prank(owner);
        staker.setMigrator(address(mig));

        _stakeAs(address(staker), alice, 10);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrateOut(_one(alice));
        staker.finalizeAndReset();
        vm.stopPrank();

        // Alice re-stakes spare units while waiting for her `migrateIn` slice,
        // so she has a live, re-accrued pending at re-injection time.
        _stakeAs(address(staker), alice, 3);
        vm.warp(block.timestamp + 3 days);

        uint256 pendingAtInject = staker.pendingReward(alice);
        assertGt(pendingAtInject, 0, "alice re-accrued before her slice ran");

        uint256 aliceBefore = phUSD.balanceOf(alice);
        vm.prank(owner);
        mig.migrateIn(0, 1);

        assertEq(phUSD.balanceOf(alice) - aliceBefore, pendingAtInject, "exact pending delivered on migrateIn");
        assertEq(phUSD.balanceOf(address(mig)), 0, "nothing stranded in the in-place migrator");
        assertEq(mig.totalUnforwarded(), 0, "nothing escrowed");
        (uint256 amt,) = staker.userInfo(alice);
        assertEq(amt, 13, "3 re-staked + 10 re-injected");
    }

    // ==================================================================
    // D. Multi-user batch incl. a ZERO-pending user: no cross-attribution.
    // ==================================================================
    function testD_MultiUserBatchNoCrossAttribution() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(oldStaker), bob, 20);
        _stakeAs(address(oldStaker), carol, 5);

        // Only alice and bob ALSO hold a position on the target staker; carol
        // has none -> zero pending there -> must receive nothing extra.
        _stakeAs(address(newStaker), alice, 4);
        _stakeAs(address(newStaker), bob, 25);

        vm.warp(block.timestamp + 30 days);

        uint256[3] memory owed;
        uint256[3] memory before;
        owed[0] = oldStaker.pendingReward(alice) + newStaker.pendingReward(alice);
        owed[1] = oldStaker.pendingReward(bob) + newStaker.pendingReward(bob);
        owed[2] = oldStaker.pendingReward(carol) + newStaker.pendingReward(carol);
        assertGt(newStaker.pendingReward(alice), 0, "alice accrued on target");
        assertGt(newStaker.pendingReward(bob), 0, "bob accrued on target");
        assertEq(newStaker.pendingReward(carol), 0, "carol has NO position on target");
        assertTrue(
            newStaker.pendingReward(alice) != newStaker.pendingReward(bob),
            "distinct per-user amounts (attribution is falsifiable)"
        );
        before[0] = phUSD.balanceOf(alice);
        before[1] = phUSD.balanceOf(bob);
        before[2] = phUSD.balanceOf(carol);

        address[] memory us = new address[](3);
        us[0] = alice;
        us[1] = bob;
        us[2] = carol;

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(us);
        vm.stopPrank();

        assertEq(phUSD.balanceOf(alice) - before[0], owed[0], "alice paid exactly HER own");
        assertEq(phUSD.balanceOf(bob) - before[1], owed[1], "bob paid exactly HIS own");
        assertEq(phUSD.balanceOf(carol) - before[2], owed[2], "carol: source leg only, no target leg");
        assertEq(phUSD.balanceOf(address(mig)), 0, "no residual, no cross-attribution");
    }

    // ==================================================================
    // E. A hook `pull()` firing mid-`depositFor` mints to the STAKER (the
    //    spec'd `recipient`), not the migrator: the delta is unaffected.
    // ==================================================================
    function testE_HookPullMintsToStakerNotMigrator() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();

        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(newStaker));
        vm.prank(owner);
        newStaker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));

        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        // Arm the hook LAST so the pull fires inside `depositFor`, not inside
        // an earlier `stake`.
        hook.setPendingMint(50_000 ether);

        uint256 owed = oldStaker.pendingReward(alice) + newStaker.pendingReward(alice);
        uint256 a0 = phUSD.balanceOf(alice);
        uint256 supplyBefore = phUSD.totalSupply();

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(hook.pendingMint(), 0, "hook DID fire inside depositFor (non-vacuous)");
        assertEq(phUSD.totalSupply() - supplyBefore, 50_000 ether, "the 50k pull really happened mid-call");
        assertEq(phUSD.balanceOf(address(mig)), 0, "migrator residual zero");
        assertEq(phUSD.balanceOf(alice) - a0, owed, "no hook inflow leaked to alice: delta == pending exactly");
    }

    // ==================================================================
    // E2. INVERTED (was `testE2_HOLE_HookRecipientPointedAtMigrator...`).
    //
    //     BASELINE BEHAVIOUR AT 0d1a0b2 (the proved hole, now killed):
    //         assertGt(aGain, owed, "HOLE CONFIRMED: mid-call inflow to the
    //             migrator is credited to the user in the loop");
    //     i.e. a 50,000e18 over-credit of real minted value onto whichever
    //     user the loop happened to be on, unrecoverable.
    //
    //     WITH the `require(captured <= owed)` tripwire the batch REVERTS
    //     instead. Loud and recoverable beats silent and permanent.
    // ==================================================================
    function testE2_MispointedHookRecipientRevertsInsteadOfOverCrediting() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        // MISCONFIGURATION / hostile-hook case: mint recipient == the migrator.
        MockUniboostMintDebtHook hook = new MockUniboostMintDebtHook(phUSD, address(mig));
        vm.prank(owner);
        newStaker.setDispatcherHook(IUniboostMintDebtHook(address(hook)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        // Arm the hook LAST so the mis-targeted mint lands mid-`depositFor`.
        hook.setPendingMint(50_000 ether);

        uint256 a0 = phUSD.balanceOf(alice);

        vm.startPrank(owner);
        mig.initiateMigration();
        vm.expectRevert(bytes("Migrator: capture exceeds owed"));
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(phUSD.balanceOf(alice), a0, "no over-credit reached alice");
        (uint256 stillOnOld,) = oldStaker.userInfo(alice);
        assertEq(stillOnOld, 10, "batch reverted wholesale; nothing half-applied");
    }

    // ==================================================================
    // F. A pre-existing donation to the migrator is not mis-attributed.
    // ==================================================================
    function testF_PreExistingDonationNotMisattributed() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        uint256 donation = 1_234 ether;
        phUSD.mint(address(mig), donation);

        uint256 owed = oldStaker.pendingReward(alice) + newStaker.pendingReward(alice);
        uint256 a0 = phUSD.balanceOf(alice);

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(phUSD.balanceOf(alice) - a0, owed, "donation NOT paid out to alice");
        assertEq(phUSD.balanceOf(address(mig)), donation, "donation stays put (per-iteration baseline snapshot)");

        // And the new rescue primitive makes it recoverable — the unpatched
        // `NFTStakerMigrator` had no recovery path of any kind.
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(phUSD)), owner, donation);
        assertEq(phUSD.balanceOf(owner), donation, "rescueERC20 recovers the donation");
        assertEq(phUSD.balanceOf(address(mig)), 0, "migrator emptied");
    }

    // ==================================================================
    // G. INVERTED (was `testG_HOLE_RevertingRecipientBricksWholeBatch`).
    //
    //     BASELINE BEHAVIOUR AT 0d1a0b2 (the proved hole, now killed):
    //         vm.expectRevert(bytes("BlocklistERC20: edge blocked"));
    //         mig.migrate(us);   // alice, a healthy user, was collateral damage
    //
    //     WITH escrow-on-failure the batch COMPLETES: alice is paid, bob's
    //     share is escrowed under `unforwarded[bob]`, `RewardForwardFailed`
    //     fires, and bob recovers it himself via `claimForwarded()`.
    // ==================================================================
    function testG_RevertingRecipientDoesNotBrickTheBatch() public {
        BlocklistERC20 tok = new BlocklistERC20();
        NFTStakerDepletion oldStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerDepletion newStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(tok)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(oldStaker), bob, 20);
        _stakeAs(address(newStaker), alice, 4);
        _stakeAs(address(newStaker), bob, 25);
        vm.warp(block.timestamp + 30 days);

        // Block ONLY the migrator -> bob edge, so every staker-side payout
        // still works and the sole failing operation is the forwarding leg.
        tok.setBlockedEdge(address(mig), bob);

        uint256 aliceOwed = oldStaker.pendingReward(alice) + newStaker.pendingReward(alice);
        uint256 bobOwedOnOld = oldStaker.pendingReward(bob);
        uint256 bobOwedOnNew = newStaker.pendingReward(bob);
        assertGt(bobOwedOnNew, 0, "bob has a target-side settlement to forward");

        uint256 a0 = tok.balanceOf(alice);
        uint256 b0 = tok.balanceOf(bob);

        address[] memory us = new address[](2);
        us[0] = alice;
        us[1] = bob;

        vm.startPrank(owner);
        mig.initiateMigration();
        vm.expectEmit(true, false, false, true, address(mig));
        emit RewardForwardFailed(bob, bobOwedOnNew);
        mig.migrate(us);
        vm.stopPrank();

        // The batch completed for BOTH users.
        (uint256 aliceOnNew,) = newStaker.userInfo(alice);
        (uint256 bobOnNew,) = newStaker.userInfo(bob);
        assertEq(aliceOnNew, 14, "alice migrated, not collateral damage");
        assertEq(bobOnNew, 45, "bob migrated too");

        assertEq(tok.balanceOf(alice) - a0, aliceOwed, "healthy user paid in full");
        assertEq(tok.balanceOf(bob) - b0, bobOwedOnOld, "bob got the source leg (staker -> bob is not blocked)");
        assertEq(mig.unforwarded(bob), bobOwedOnNew, "bob's target leg escrowed, attributed on-chain");
        assertEq(mig.totalUnforwarded(), bobOwedOnNew, "totalUnforwarded tracks the escrow");
        assertEq(tok.balanceOf(address(mig)), bobOwedOnNew, "residual == escrow exactly");

        // Bob recovers it himself once the edge is unblocked. No owner path.
        tok.setBlockedEdge(address(0), address(0));
        vm.prank(bob);
        mig.claimForwarded();
        assertEq(tok.balanceOf(bob) - b0, bobOwedOnOld + bobOwedOnNew, "bob made whole via claimForwarded");
        assertEq(mig.unforwarded(bob), 0, "escrow zeroed");
        assertEq(mig.totalUnforwarded(), 0, "totalUnforwarded zeroed");
        assertEq(tok.balanceOf(address(mig)), 0, "migrator emptied");
    }

    /// @notice The OTHER escrow branch: a token that returns `false` without
    ///         reverting. A bare `safeTransfer` would have reverted the batch;
    ///         `try ... returns (bool ok)` catches it and escrows instead.
    function testG2_FalseReturningTransferEscrowsRatherThanReverting() public {
        FalseReturningERC20 tok = new FalseReturningERC20();
        NFTStakerDepletion oldStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerDepletion newStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(tok)));

        _stakeAs(address(oldStaker), alice, 10);
        _stakeAs(address(newStaker), alice, 4);
        vm.warp(block.timestamp + 30 days);

        tok.setBlockedEdge(address(mig), alice);
        uint256 owedOnNew = newStaker.pendingReward(alice);
        assertGt(owedOnNew, 0, "alice has a target-side settlement to forward");

        vm.startPrank(owner);
        mig.initiateMigration();
        vm.expectEmit(true, false, false, true, address(mig));
        emit RewardForwardFailed(alice, owedOnNew);
        mig.migrate(_one(alice));
        vm.stopPrank();

        assertEq(mig.unforwarded(alice), owedOnNew, "false-return escrowed, not reverted");
        assertEq(mig.totalUnforwarded(), owedOnNew, "totalUnforwarded tracks it");

        tok.setBlockedEdge(address(0), address(0));
        vm.prank(alice);
        mig.claimForwarded();
        assertEq(mig.totalUnforwarded(), 0, "recovered");
    }

    // ==================================================================
    // H. Both constructor reward-token cross-checks are live.
    // ==================================================================
    function testH_ConstructorRejectsWrongRewardToken() public {
        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        MockERC20 wrong = new MockERC20("NOT-phUSD", "X");
        NFTStakerDepletion wrongStaker = _newDepletionWithToken(IERC20(address(wrong)));

        // Zero-token guard.
        vm.expectRevert(bytes("Migrator: zero reward token"));
        new NFTStakerMigrator(
            INFTStakerMigratable(address(oldStaker)),
            INFTStakerMigratable(address(newStaker)),
            IERC1155(address(nft)),
            ID,
            IERC20(address(0)),
            owner
        );

        // TARGET staker's `rewardToken()` disagrees.
        vm.expectRevert(bytes("Migrator: reward token mismatch (new)"));
        new NFTStakerMigrator(
            INFTStakerMigratable(address(oldStaker)),
            INFTStakerMigratable(address(newStaker)),
            IERC1155(address(nft)),
            ID,
            IERC20(address(wrong)),
            owner
        );

        // SOURCE staker's `rewardToken()` disagrees (target agrees, so the
        // "(new)" check passes and the "(old)" check is the one that fires).
        vm.expectRevert(bytes("Migrator: reward token mismatch (old)"));
        new NFTStakerMigrator(
            INFTStakerMigratable(address(oldStaker)),
            INFTStakerMigratable(address(wrongStaker)),
            IERC1155(address(nft)),
            ID,
            IERC20(address(wrong)),
            owner
        );

        // In-place equivalents.
        vm.expectRevert(bytes("InPlace: zero reward token"));
        new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(newStaker)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(0)), owner
        );
        vm.expectRevert(bytes("InPlace: reward token mismatch"));
        new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(newStaker)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(wrong)), owner
        );
    }

    // ==================================================================
    // VERSION-AGNOSTIC PAIR — the SAME migrator source, unchanged, run
    // against a `_safePay` staker (`NFTStakerDepletion`) and against a
    // `_safePayTo` staker (`NFTStakerPriceScaledMigrateReady`).
    //
    // The invariant that earns the phrase "works for every staker with
    // `depositFor`" is identical in both runs: each user's reward-balance
    // delta equals their `pendingReward` on BOTH legs. Only the ROUTE
    // differs — the depletion pair needs a forward (capture > 0, a
    // `RewardForwarded` event fires), the price-scaled pair does not
    // (capture == 0, the branch self-disables and NO event fires).
    // ==================================================================
    function testVersionAgnosticPairDepletionVsPriceScaled() public {
        // --- leg 1: the `_safePay` staker. Capture is NON-zero. ---
        uint256 depletionDelta;
        uint256 depletionOwed;
        {
            NFTStakerDepletion oldS = _newDepletion();
            NFTStakerDepletion newS = _newDepletion();
            NFTStakerMigrator mig = _newCrossMigrator(address(oldS), address(newS), IERC20(address(phUSD)));

            _stakeAs(address(oldS), alice, 10);
            _stakeAs(address(newS), alice, 4);
            vm.warp(block.timestamp + 30 days);

            depletionOwed = oldS.pendingReward(alice) + newS.pendingReward(alice);
            assertGt(newS.pendingReward(alice), 0, "target-side accrual exists on the depletion pair");
            uint256 a0 = phUSD.balanceOf(alice);

            vm.startPrank(owner);
            mig.initiateMigration();
            vm.recordLogs();
            mig.migrate(_one(alice));
            vm.stopPrank();

            assertEq(_countForwardEvents(vm.getRecordedLogs(), address(mig)), 1, "_safePay staker: capture > 0");
            depletionDelta = phUSD.balanceOf(alice) - a0;
            assertEq(depletionDelta, depletionOwed, "depletion pair: exact pending delivered");
            assertEq(phUSD.balanceOf(address(mig)), 0, "depletion pair: residual 0");
        }

        // --- leg 2: the `_safePayTo` staker. Capture is ZERO. ---
        uint256 scaledDelta;
        uint256 scaledOwed;
        {
            NFTStakerPriceScaledMigrateReady oldS = _newPriceScaled();
            NFTStakerPriceScaledMigrateReady newS = _newPriceScaled();
            NFTStakerMigrator mig = _newCrossMigrator(address(oldS), address(newS), IERC20(address(phUSD)));

            _stakeAs(address(oldS), bob, 10);
            _stakeAs(address(newS), bob, 4);
            vm.warp(block.timestamp + 30 days);

            scaledOwed = oldS.pendingReward(bob) + newS.pendingReward(bob);
            assertGt(newS.pendingReward(bob), 0, "target-side accrual exists on the price-scaled pair too");
            uint256 b0 = phUSD.balanceOf(bob);

            vm.startPrank(owner);
            mig.initiateMigration();
            vm.recordLogs();
            mig.migrate(_one(bob));
            vm.stopPrank();

            // THE version-agnostic assertion: the forwarding branch never ran,
            // because the staker settled to the user directly.
            assertEq(_countForwardEvents(vm.getRecordedLogs(), address(mig)), 0, "_safePayTo staker: captured == 0");
            scaledDelta = phUSD.balanceOf(bob) - b0;
            assertEq(scaledDelta, scaledOwed, "price-scaled pair: exact pending delivered");
            assertEq(phUSD.balanceOf(address(mig)), 0, "price-scaled pair: residual 0");
        }

        // Identical OUTCOME under both staker variants: delta == owed, always.
        assertEq(depletionDelta, depletionOwed, "same outcome shape, `_safePay` variant");
        assertEq(scaledDelta, scaledOwed, "same outcome shape, `_safePayTo` variant");
    }

    /// @dev The in-place orchestrator against the `_safePayTo` staker: the
    ///      forwarding branch must likewise self-disable there.
    function testVersionAgnosticInPlaceAgainstPriceScaled() public {
        NFTStakerPriceScaledMigrateReady s = _newPriceScaled();
        InPlaceNFTStakerMigrator mig = new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(s)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner
        );
        vm.prank(owner);
        s.setMigrator(address(mig));

        _stakeAs(address(s), alice, 10);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrateOut(_one(alice));
        s.finalizeAndReset();
        vm.stopPrank();

        _stakeAs(address(s), alice, 3);
        vm.warp(block.timestamp + 3 days);

        uint256 owed = s.pendingReward(alice);
        assertGt(owed, 0, "alice re-accrued before her slice ran");
        uint256 a0 = phUSD.balanceOf(alice);

        vm.recordLogs();
        vm.prank(owner);
        mig.migrateIn(0, 1);

        assertEq(_countForwardEvents(vm.getRecordedLogs(), address(mig)), 0, "_safePayTo staker: captured == 0");
        assertEq(phUSD.balanceOf(alice) - a0, owed, "exact pending delivered without any forward");
        assertEq(phUSD.balanceOf(address(mig)), 0, "residual 0");
    }

    /// @dev Story-026: the SAME version-agnostic property against
    ///      `NFTStakerDepletionV2` — like `NFTStakerPriceScaledMigrateReady`,
    ///      a `_safePayTo(user, ...)` staker (audit-21 M-03 fixed). The
    ///      cross-staker migrator's capture-and-forward leg must SELF-DISABLE
    ///      (captured == 0, no `RewardForwarded` event) while the user still
    ///      receives their exact pending on both legs. Same shape as
    ///      `testVersionAgnosticPairDepletionVsPriceScaled` leg 2.
    function testVersionAgnosticCrossMigratorAgainstDepletionV2() public {
        NFTStakerDepletionV2 oldS = _newDepletionV2();
        NFTStakerDepletionV2 newS = _newDepletionV2();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldS), address(newS), IERC20(address(phUSD)));

        _stakeAs(address(oldS), alice, 10);
        _stakeAs(address(newS), alice, 4);
        vm.warp(block.timestamp + 30 days);

        uint256 owed = oldS.pendingReward(alice) + newS.pendingReward(alice);
        assertGt(newS.pendingReward(alice), 0, "target-side accrual exists on the V2 pair");
        uint256 a0 = phUSD.balanceOf(alice);

        vm.startPrank(owner);
        mig.initiateMigration();
        vm.recordLogs();
        mig.migrate(_one(alice));
        vm.stopPrank();

        // THE version-agnostic assertion: the forwarding branch never ran,
        // because V2's `depositFor` settled the pending to the user directly.
        assertEq(_countForwardEvents(vm.getRecordedLogs(), address(mig)), 0, "V2 staker: captured == 0");
        assertEq(phUSD.balanceOf(alice) - a0, owed, "V2 pair: exact pending delivered without any forward");
        assertEq(phUSD.balanceOf(address(mig)), 0, "V2 pair: residual 0");
        (uint256 amt,) = newS.userInfo(alice);
        assertEq(amt, 14, "stake credited (4 pre-existing + 10 migrated)");
    }

    /// @dev Story-026: the in-place orchestrator against `NFTStakerDepletionV2`
    ///      — the forwarding branch must likewise self-disable (captured == 0)
    ///      and the user receives their exact pending. Same shape as
    ///      `testVersionAgnosticInPlaceAgainstPriceScaled`.
    function testVersionAgnosticInPlaceAgainstDepletionV2() public {
        NFTStakerDepletionV2 s = _newDepletionV2();
        InPlaceNFTStakerMigrator mig = new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(s)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(phUSD)), owner
        );
        vm.prank(owner);
        s.setMigrator(address(mig));

        _stakeAs(address(s), alice, 10);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrateOut(_one(alice));
        s.finalizeAndReset();
        vm.stopPrank();

        _stakeAs(address(s), alice, 3);
        vm.warp(block.timestamp + 3 days);

        uint256 owed = s.pendingReward(alice);
        assertGt(owed, 0, "alice re-accrued before her slice ran");
        uint256 a0 = phUSD.balanceOf(alice);

        vm.recordLogs();
        vm.prank(owner);
        mig.migrateIn(0, 1);

        assertEq(_countForwardEvents(vm.getRecordedLogs(), address(mig)), 0, "V2 staker: captured == 0");
        assertEq(phUSD.balanceOf(alice) - a0, owed, "exact pending delivered without any forward");
        assertEq(phUSD.balanceOf(address(mig)), 0, "residual 0");
    }

    // ==================================================================
    // rescueERC20 floors
    // ==================================================================

    function testRescueERC20FlooredByTotalUnforwarded() public {
        BlocklistERC20 tok = new BlocklistERC20();
        NFTStakerDepletion oldStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerDepletion newStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(tok)));

        _stakeAs(address(oldStaker), bob, 20);
        _stakeAs(address(newStaker), bob, 25);
        vm.warp(block.timestamp + 30 days);

        tok.setBlockedEdge(address(mig), bob);
        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(_one(bob));
        vm.stopPrank();

        uint256 escrowed = mig.totalUnforwarded();
        assertGt(escrowed, 0, "escrow is live");

        // Nothing above the floor yet -> even 1 wei is refused.
        vm.expectRevert(bytes("Migrator: cannot touch unforwarded"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(tok)), owner, escrowed);

        // Donate a surplus; exactly the surplus is sweepable, one wei more is not.
        uint256 donation = 500 ether;
        tok.mint(address(mig), donation);
        vm.expectRevert(bytes("Migrator: cannot touch unforwarded"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(tok)), owner, donation + 1);

        vm.prank(owner);
        mig.rescueERC20(IERC20(address(tok)), owner, donation);
        assertEq(tok.balanceOf(owner), donation, "surplus swept");
        assertEq(tok.balanceOf(address(mig)), escrowed, "escrow floor intact");

        // A NON-reward token stays an unconditional sweep.
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(mig), 1_000 ether);
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(other)), carol, 1_000 ether);
        assertEq(other.balanceOf(carol), 1_000 ether, "non-reward token unaffected by the floor");

        // Zero-recipient guard.
        vm.expectRevert(bytes("Migrator: zero recipient"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(other)), address(0), 0);
    }

    function testInPlaceRescueERC20FlooredByTotalUnforwarded() public {
        BlocklistERC20 tok = new BlocklistERC20();
        NFTStakerDepletion staker = _newDepletionWithToken(IERC20(address(tok)));
        InPlaceNFTStakerMigrator mig = new InPlaceNFTStakerMigrator(
            INFTStakerMigratable(address(staker)), IERC1155(address(nft)), ID, TIMEOUT, IERC20(address(tok)), owner
        );
        vm.prank(owner);
        staker.setMigrator(address(mig));

        _stakeAs(address(staker), alice, 10);
        vm.warp(block.timestamp + 30 days);

        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrateOut(_one(alice));
        staker.finalizeAndReset();
        vm.stopPrank();

        _stakeAs(address(staker), alice, 3);
        vm.warp(block.timestamp + 3 days);

        uint256 owed = staker.pendingReward(alice);
        assertGt(owed, 0, "alice re-accrued");
        tok.setBlockedEdge(address(mig), alice);

        vm.prank(owner);
        mig.migrateIn(0, 1);

        assertEq(mig.unforwarded(alice), owed, "escrowed on the in-place path too");
        assertEq(mig.totalUnforwarded(), owed, "totalUnforwarded tracks it");

        vm.expectRevert(bytes("InPlace: cannot touch unforwarded"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(tok)), owner, owed);

        // Non-reward token remains an unconditional sweep.
        MockERC20 other = new MockERC20("Other", "OTH");
        other.mint(address(mig), 42 ether);
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(other)), bob, 42 ether);
        assertEq(other.balanceOf(bob), 42 ether, "non-reward token unaffected");

        // Alice recovers her own escrow.
        tok.setBlockedEdge(address(0), address(0));
        vm.prank(alice);
        mig.claimForwarded();
        assertEq(tok.balanceOf(address(mig)), 0, "in-place migrator emptied");
    }

    // ==================================================================
    // claimForwarded: self-only, pays once, zeroes state.
    // ==================================================================
    function testClaimForwardedIsSelfOnlyAndPaysOnce() public {
        BlocklistERC20 tok = new BlocklistERC20();
        NFTStakerDepletion oldStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerDepletion newStaker = _newDepletionWithToken(IERC20(address(tok)));
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(tok)));

        _stakeAs(address(oldStaker), bob, 20);
        _stakeAs(address(newStaker), bob, 25);
        vm.warp(block.timestamp + 30 days);

        tok.setBlockedEdge(address(mig), bob);
        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(_one(bob));
        vm.stopPrank();

        uint256 escrowed = mig.unforwarded(bob);
        assertGt(escrowed, 0, "bob has escrow");
        tok.setBlockedEdge(address(0), address(0));

        // A stranger with no escrow cannot claim — and cannot claim bob's.
        vm.expectRevert(bytes("Migrator: nothing unforwarded"));
        vm.prank(carol);
        mig.claimForwarded();
        assertEq(mig.unforwarded(bob), escrowed, "bob's escrow untouched by the stranger");

        // The OWNER has no path to it either: `rescueERC20` is floored.
        vm.expectRevert(bytes("Migrator: cannot touch unforwarded"));
        vm.prank(owner);
        mig.rescueERC20(IERC20(address(tok)), owner, escrowed);

        uint256 b0 = tok.balanceOf(bob);
        vm.prank(bob);
        mig.claimForwarded();
        assertEq(tok.balanceOf(bob) - b0, escrowed, "paid once");
        assertEq(mig.unforwarded(bob), 0, "state zeroed");
        assertEq(mig.totalUnforwarded(), 0, "total zeroed");

        // No double claim.
        vm.expectRevert(bytes("Migrator: nothing unforwarded"));
        vm.prank(bob);
        mig.claimForwarded();
    }

    // ==================================================================
    // FUZZ / INVARIANT — for ANY batch:
    //   Σ (user reward-balance delta) == Σ (owed at call time)
    //   migrator reward residual      == totalUnforwarded
    // ==================================================================
    function testFuzz_BatchConservesOwedAndResidualEqualsEscrow(uint96 aOld, uint96 bOld, uint96 aNew, uint96 bNew)
        public
    {
        aOld = uint96(bound(aOld, 1, 1_000));
        bOld = uint96(bound(bOld, 1, 1_000));
        aNew = uint96(bound(aNew, 0, 1_000));
        bNew = uint96(bound(bNew, 0, 1_000));

        NFTStakerDepletion oldStaker = _newDepletion();
        NFTStakerDepletion newStaker = _newDepletion();
        NFTStakerMigrator mig = _newCrossMigrator(address(oldStaker), address(newStaker), IERC20(address(phUSD)));

        _stakeAs(address(oldStaker), alice, aOld);
        _stakeAs(address(oldStaker), bob, bOld);
        if (aNew > 0) _stakeAs(address(newStaker), alice, aNew);
        if (bNew > 0) _stakeAs(address(newStaker), bob, bNew);

        vm.warp(block.timestamp + 30 days);

        uint256 owedTotal = oldStaker.pendingReward(alice) + newStaker.pendingReward(alice)
            + oldStaker.pendingReward(bob) + newStaker.pendingReward(bob);
        uint256 before = phUSD.balanceOf(alice) + phUSD.balanceOf(bob);

        address[] memory us = new address[](2);
        us[0] = alice;
        us[1] = bob;
        vm.startPrank(owner);
        mig.initiateMigration();
        mig.migrate(us);
        vm.stopPrank();

        uint256 delta = phUSD.balanceOf(alice) + phUSD.balanceOf(bob) - before;
        assertEq(delta, owedTotal, "sum of user deltas == sum of owed at call time");
        assertEq(phUSD.balanceOf(address(mig)), mig.totalUnforwarded(), "residual == escrow");
        assertEq(mig.totalUnforwarded(), 0, "healthy token: nothing escrowed");
    }
}
