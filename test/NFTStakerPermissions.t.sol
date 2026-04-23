// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {NFTStaker} from "../src/NFTStaker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC1155} from "./mocks/MockERC1155.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBalancerPoolerMintDebtHook} from "./mocks/MockBalancerPoolerMintDebtHook.sol";

/// @notice Covers the `minPullInterval` cooldown that gates user-path
///         `_syncBudget` pulls, plus the owner-only access controls on
///         `topUp`, `pullAndRefresh`, and `setMinPullInterval`.
///
///         This suite replaces the pre-story-004 `ownerOrNotGriefed`
///         decision-table tests. It mirrors the regression coverage called
///         out in the M-01 audit submission.
contract NFTStakerCooldownTest is Test {
    NFTStaker internal staker;
    MockERC1155 internal nft;
    MockERC20 internal phUSD;
    MockBalancerPoolerMintDebtHook internal hook;

    address internal owner = address(0xD1);
    address internal stranger = address(0xBEEF);
    address internal user = address(0xA1);
    address internal attacker = address(0xBAD);
    address internal attacker2 = address(0xBAD2);

    uint256 internal constant INITIAL_ID = 1;
    uint256 internal constant STAKE_AMOUNT = 10;

    event Pulled(uint256 inflow, uint256 newBudget, uint256 newRate, uint256 newWindowEnd);
    event MinPullIntervalChanged(uint256 previous, uint256 next);

    function setUp() public {
        nft = new MockERC1155();
        phUSD = new MockERC20("phUSD", "phUSD");
        staker = new NFTStaker(IERC1155(address(nft)), INITIAL_ID, IERC20(address(phUSD)), owner);
        hook = new MockBalancerPoolerMintDebtHook(phUSD, address(staker));
        vm.prank(owner);
        staker.setDispatcherHook(IBalancerPoolerMintDebtHook(address(hook)));

        nft.mint(user, INITIAL_ID, STAKE_AMOUNT);
        vm.prank(user);
        nft.setApprovalForAll(address(staker), true);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _ownerSeed(uint256 amount) internal {
        phUSD.mint(owner, amount);
        vm.prank(owner);
        phUSD.approve(address(staker), amount);
        vm.prank(owner);
        staker.topUp(amount);
    }

    function _userStake() internal {
        vm.prank(user);
        staker.stake(STAKE_AMOUNT);
    }

    function _setInterval(uint256 interval) internal {
        vm.prank(owner);
        staker.setMinPullInterval(interval);
    }

    // ---------------------------------------------------------------------
    // 1. Cooldown enforced on user paths (M-01 PoC replacement)
    // ---------------------------------------------------------------------

    function test_cooldown_userPath_noops_withinInterval() public {
        uint256 interval = 1 days;
        _setInterval(interval);

        // Seed and stake so a legitimate schedule is in flight.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        // Prime `lastPullAt` via an owner bypass so the cooldown clock
        // starts from a known, non-zero timestamp. Without this, the first
        // user call at block.timestamp=1 would itself be cooldown-gated
        // (since 1 < 0 + 1 days), obscuring the test's focus on the
        // post-prime gate behavior.
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 stampedAt = staker.lastPullAt();
        assertEq(stampedAt, block.timestamp, "owner prime should stamp lastPullAt");

        // Warp less than the interval, set a large pending mint, call claim
        // from a zero-stake attacker. The cooldown must gate the pull.
        vm.warp(block.timestamp + interval - 1);
        uint256 big = 540 days * 200;
        hook.setPendingMint(big);

        uint256 rateBefore = staker.rewardRate();
        uint256 endBefore = staker.windowEnd();

        vm.recordLogs();
        vm.prank(attacker);
        staker.claim();

        // Cooldown gate tripped: lastPullAt unchanged, rate / window / hook
        // untouched, no Pulled event emitted. `rewardBudget` naturally drains
        // under `_updatePool` (which always runs) but the schedule-reset
        // effect (the griefer's target) is fully blocked.
        assertEq(staker.lastPullAt(), stampedAt, "cooldown should not advance lastPullAt");
        assertEq(staker.rewardRate(), rateBefore, "rate changed despite cooldown");
        assertEq(staker.windowEnd(), endBefore, "window changed despite cooldown");
        assertEq(hook.pendingMint(), big, "hook was called despite cooldown");

        bytes32 pulledSig = keccak256("Pulled(uint256,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != pulledSig, "Pulled emitted despite cooldown");
            }
        }
    }

    // ---------------------------------------------------------------------
    // 2. Cooldown expiry + successful pull
    // ---------------------------------------------------------------------

    function test_cooldown_expires_userPullSucceeds() public {
        uint256 interval = 1 days;
        _setInterval(interval);

        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        // Burn the initial pull.
        vm.prank(user);
        staker.claim();
        uint256 firstStamp = staker.lastPullAt();

        // Warp to exactly lastPullAt + interval (the boundary — must be
        // permitted by the `block.timestamp < lastPullAt + interval` check).
        vm.warp(firstStamp + interval);

        uint256 inflow = 540 days * 50;
        hook.setPendingMint(inflow);
        uint256 budgetBefore = staker.rewardBudget();

        vm.prank(user);
        staker.claim();

        assertEq(staker.lastPullAt(), block.timestamp, "lastPullAt not advanced after cooldown");
        assertGt(staker.rewardBudget(), budgetBefore, "budget did not increase after cooldown pull");
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration(), "window did not reset");
        assertEq(hook.pendingMint(), 0, "hook pending not cleared");
    }

    // ---------------------------------------------------------------------
    // 3. Owner bypass via pullAndRefresh
    // ---------------------------------------------------------------------

    function test_owner_pullAndRefresh_bypassesCooldown() public {
        uint256 interval = 30 days;
        _setInterval(interval);

        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        // Prime lastPullAt via a first user interaction.
        vm.prank(user);
        staker.claim();

        // Warp forward less than the interval; a user call would be gated.
        vm.warp(block.timestamp + 1 days);

        uint256 inflow = 540 days * 25;
        hook.setPendingMint(inflow);
        uint256 budgetBefore = staker.rewardBudget();

        vm.prank(owner);
        staker.pullAndRefresh();

        // Owner bypass forced a pull despite the cooldown being active.
        assertEq(staker.lastPullAt(), block.timestamp, "owner path did not stamp lastPullAt");
        assertGt(staker.rewardBudget(), budgetBefore, "owner bypass did not import inflow");
        assertEq(hook.pendingMint(), 0, "hook pending not cleared after owner bypass");
    }

    // ---------------------------------------------------------------------
    // 4. Owner bypass via topUp does NOT touch the cooldown clock
    // ---------------------------------------------------------------------

    function test_owner_topUp_doesNotTouchLastPullAt() public {
        uint256 interval = 30 days;
        _setInterval(interval);

        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        // Prime lastPullAt via owner bypass (user path is cooldown-gated at
        // block.timestamp < interval).
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        staker.pullAndRefresh();
        uint256 stampBefore = staker.lastPullAt();

        // Warp forward less than the interval and owner tops up.
        vm.warp(block.timestamp + 2 days);

        uint256 extra = 540 days * 50;
        phUSD.mint(owner, extra);
        vm.prank(owner);
        phUSD.approve(address(staker), extra);

        // topUp calls _updatePool first, so capture the budget *after*
        // draining the elapsed emissions to compute the expected delta.
        uint256 rate = staker.rewardRate();
        uint256 elapsed = block.timestamp - staker.lastRewardTime();
        uint256 drained = rate * elapsed;
        uint256 budgetBefore = staker.rewardBudget();

        vm.prank(owner);
        staker.topUp(extra);

        // topUp must reset the schedule, but leave lastPullAt alone.
        assertEq(staker.lastPullAt(), stampBefore, "topUp must not advance lastPullAt");
        assertEq(staker.rewardBudget(), budgetBefore - drained + extra, "topUp did not add amount");
        assertEq(staker.windowEnd(), block.timestamp + staker.windowDuration(), "topUp did not reset window");
        assertGt(staker.rewardRate(), 0, "rate did not recompute");
    }

    // ---------------------------------------------------------------------
    // 5. Access control — non-owner reverts
    // ---------------------------------------------------------------------

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

    function test_nonOwner_setMinPullInterval_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        staker.setMinPullInterval(123);
    }

    // ---------------------------------------------------------------------
    // 6. Setter semantics
    // ---------------------------------------------------------------------

    function test_setMinPullInterval_updatesStorageAndEmits() public {
        assertEq(staker.minPullInterval(), 0);

        vm.expectEmit(true, true, true, true, address(staker));
        emit MinPullIntervalChanged(0, 1 days);

        vm.prank(owner);
        staker.setMinPullInterval(1 days);

        assertEq(staker.minPullInterval(), 1 days);

        // Second update emits the previous value (1 days), not 0.
        vm.expectEmit(true, true, true, true, address(staker));
        emit MinPullIntervalChanged(1 days, 7 days);

        vm.prank(owner);
        staker.setMinPullInterval(7 days);

        assertEq(staker.minPullInterval(), 7 days);
    }

    function test_setMinPullInterval_takesEffectImmediately() public {
        // Seed, stake, prime lastPullAt.
        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        vm.prank(user);
        staker.claim();
        uint256 stamp = staker.lastPullAt();

        // Before the setter, another user call in the same block would pull
        // again (interval is 0). Owner sets interval; the very next user
        // call must now be gated.
        _setInterval(1 days);

        uint256 big = 540 days * 200;
        hook.setPendingMint(big);

        vm.prank(user);
        staker.claim();

        assertEq(staker.lastPullAt(), stamp, "interval not effective immediately");
        assertEq(hook.pendingMint(), big, "hook was pulled despite fresh interval");
    }

    // ---------------------------------------------------------------------
    // 7. Zero-interval compatibility (pre-fix behavior preserved)
    // ---------------------------------------------------------------------

    function test_zeroInterval_pullsOnEveryUserInteraction() public {
        // minPullInterval defaults to 0; never touch the setter.
        assertEq(staker.minPullInterval(), 0);

        uint256 seed = 540 days * 100;
        _ownerSeed(seed);
        _userStake();

        // Each user interaction should invoke the hook when pending > 0.
        uint256 inflow = 540 days * 10;
        hook.setPendingMint(inflow);
        vm.prank(user);
        staker.claim();
        assertEq(hook.pendingMint(), 0, "first claim did not pull");
        uint256 stamp1 = staker.lastPullAt();
        assertEq(stamp1, block.timestamp, "first claim did not stamp");

        // Second interaction in the same block: zero pending, but the pull
        // still runs (interval is 0) — lastPullAt just re-stamps to the
        // same timestamp.
        vm.prank(user);
        staker.claim();
        assertEq(staker.lastPullAt(), block.timestamp, "second claim did not re-stamp");

        // Warp and set a new inflow; next interaction pulls again (no gate).
        vm.warp(block.timestamp + 1);
        uint256 inflow2 = 540 days * 10;
        hook.setPendingMint(inflow2);
        vm.prank(user);
        staker.claim();
        assertEq(hook.pendingMint(), 0, "post-warp claim did not pull with zero interval");
    }

    // ---------------------------------------------------------------------
    // 8. Griefer scenario (M-01 regression)
    // ---------------------------------------------------------------------

    function test_M01_regression_cooldownBlocksGriefer() public {
        uint256 interval = 1 days;
        _setInterval(interval);

        // Owner seeds a 10-day window with 10,000 phUSD.
        vm.prank(owner);
        staker.setWindowDuration(10 days);

        uint256 seed = 10_000 ether;
        _ownerSeed(seed);
        _userStake();

        uint256 rateAfterSeed = staker.rewardRate();
        assertGt(rateAfterSeed, 0);

        // Warp 1 day; budget has drained at the legitimate rate.
        vm.warp(block.timestamp + 1 days);

        // Attacker EOA with zero stake calls claim(): first call triggers
        // the pull because lastPullAt is 0.
        uint256 tinyInflow = 1;
        hook.setPendingMint(tinyInflow);

        vm.prank(attacker);
        staker.claim();
        uint256 firstStamp = staker.lastPullAt();
        assertEq(firstStamp, block.timestamp, "first griefer pull did not stamp");

        // The first pull DID dilute the rate (that's the unavoidable cost
        // of any rate-limited scheme once per interval). Record the
        // post-dilution rate as the floor the cooldown must protect.
        uint256 rateAfterFirstPull = staker.rewardRate();

        // Immediate second griefer (different EOA, still zero stake) tries
        // to poke again. Cooldown must block any further dilution.
        uint256 tinyAgain = 1;
        hook.setPendingMint(tinyAgain);

        vm.prank(attacker2);
        staker.claim();

        assertEq(staker.lastPullAt(), firstStamp, "cooldown did not block second griefer");
        assertEq(staker.rewardRate(), rateAfterFirstPull, "rate drifted despite cooldown");
        assertEq(hook.pendingMint(), tinyAgain, "hook pulled during cooldown");

        // Attacker spams claim() repeatedly inside the cooldown window —
        // none can pin the rate any lower.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 100);
            hook.setPendingMint(1);
            vm.prank(attacker);
            staker.claim();
            assertEq(staker.rewardRate(), rateAfterFirstPull, "repeated griefer advanced rate");
            assertEq(staker.lastPullAt(), firstStamp, "repeated griefer advanced stamp");
        }
    }

    // ---------------------------------------------------------------------
    // 9. Zero-inflow pull still stamps cooldown
    // ---------------------------------------------------------------------

    function test_zeroInflowPull_stillStampsLastPullAt() public {
        uint256 interval = 1 days;
        _setInterval(interval);

        // No seed, hook returns zero on pull.
        _userStake();
        hook.setPendingMint(0);

        // Warp past the initial cooldown window so the first user-path call
        // is not itself gated by `block.timestamp < 0 + interval`.
        vm.warp(block.timestamp + interval);

        uint256 balanceBefore = phUSD.balanceOf(address(staker));

        vm.prank(user);
        staker.claim();

        uint256 firstStamp = staker.lastPullAt();
        assertEq(firstStamp, block.timestamp, "zero-inflow pull must still stamp");
        assertEq(phUSD.balanceOf(address(staker)), balanceBefore, "zero-inflow changed balance");

        // Second call in the same block: the cooldown gate should kick in
        // before `dispatcherHook.pull()` runs, leaving `lastPullAt` frozen.
        vm.prank(user);
        staker.claim();

        assertEq(staker.lastPullAt(), firstStamp, "cooldown allowed re-entry");
    }
}
