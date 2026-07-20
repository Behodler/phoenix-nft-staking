// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INFTStakerMigratable} from "./INFTStakerMigratable.sol";
import {IStakerViews} from "./IStakerViews.sol";

/// @title  NFTStakerMigrator
/// @notice Orchestrates a zero-user-action migration between two
///         `NFTStakerDepletion` instances. The nft-staking analogue of
///         `StableStakerMigrator`.
///
/// @dev    The owner calls `migrate(users)`. The migrator pulls those users'
///         ERC1155 stake out of the old staker (which also settles + mints each
///         user's earned phUSD to them), then re-deposits the same ERC1155 into
///         the new staker crediting the same users. No staker needs to act.
///
///         WIRING: the migrator must be set as `migrator` on BOTH stakers (via
///         `setMigrator`), the new staker must already be deployed and wired
///         (hook + dispatcherIndex), and BOTH stakers must share the same
///         `stakedToken` and `stakedId` so the parked ERC1155 is fungible
///         between them. The migrator implements `ERC1155Holder` to take
///         temporary custody of the staked ERC1155 between the
///         `batchMigrate` pull and the `depositFor` push.
///
///         NO HAIRCUT: unlike stable-staker (which can socialize an underwater
///         yield-strategy loss via an `(R, P)` snapshot), the Uniboost staker
///         moves exact ERC1155 amounts. `batchMigrate` returns each user's
///         exact staked amount and `depositFor` credits exactly that amount, so
///         the per-user redeposit always matches what was pulled in — no
///         top-up logic is required.
///
///         SETTLEMENT-CAPTURE FORWARDING (audit `pns20h1`): some deployed
///         stakers settle the incoming user's pending reward inside
///         `depositFor` with `_safePay(...)`, which pays `msg.sender` — i.e.
///         THIS CONTRACT — rather than the user (`NFTStakerDepletion.sol:756`).
///         Others settle correctly with `_safePayTo(user, ...)`
///         (`NFTStakerPriceScaledMigrateReady.sol:887`). Those stakers are
///         deployed and immutable, so the migrator compensates instead: around
///         every `depositFor` it snapshots the user's `pendingReward` and its
///         own reward-token balance, measures the capture as a balance delta,
///         bounds it by the pre-call `pendingReward`, and forwards it to the
///         user. Against a correct staker the measured capture is ZERO and no
///         transfer occurs, so the branch is self-disabling and this contract
///         is version-agnostic across every staker exposing `depositFor`.
///
///         THE BOUND IS A TRIPWIRE, NOT A HAIRCUT. `_syncBudget()` runs
///         `_updatePool()` before `dispatcherHook.pull()`, so the accrual
///         `depositFor` settles is computed against the pre-pull budget —
///         exactly the quantity `pendingReward(user)` projects at the same
///         timestamp. `require(captured <= owed)` therefore cannot fire on a
///         legitimate migration; it fires only when foreign value lands on the
///         migrator mid-call (e.g. a dispatcher hook whose `recipient` is
///         mispointed at this contract), which would otherwise be misattributed
///         to whichever user the loop happens to be on.
///
///         ESCROW-ON-FAILURE. The forward is attempted inside `try`/`catch`; a
///         reverting or `false`-returning recipient credits `unforwarded[user]`
///         and emits `RewardForwardFailed` instead of taking the whole batch
///         down with it. The user recovers via the permissionless, self-only
///         `claimForwarded()`. `totalUnforwarded` is a floor `rescueERC20` may
///         not cross for the reward token, so no owner path can redirect
///         escrowed value.
///
///         OFF-CHAIN RECONCILIATION CAVEAT. The staker still emits
///         `Claimed(user, pending)` before the forward completes, so a settled
///         payment can traverse TWO transfers (staker -> migrator -> user) under
///         ONE `Claimed` event. Indexers keying on `Claimed` alone will
///         mis-source the payment; join it with `RewardForwarded` /
///         `RewardForwardFailed` from this contract to reconstruct the true
///         flow. No on-chain change compensates for this.
contract NFTStakerMigrator is Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    /// @notice The staker users are migrating out of.
    INFTStakerMigratable public immutable oldStaker;

    /// @notice The staker users are migrating into.
    INFTStakerMigratable public immutable newStaker;

    /// @notice The shared ERC1155 stake token (must match on both stakers).
    IERC1155 public immutable stakedToken;

    /// @notice The shared ERC1155 stake ID (must match on both stakers).
    uint256 public immutable stakedId;

    /// @notice The reward token (phUSD) both stakers emit. Supplied as a
    ///         constructor arg because `INFTStakerMigratable` does not expose
    ///         `rewardToken()`, and cross-checked against both stakers' own
    ///         getters — a mismatch would mean the forwarding logic measures
    ///         the wrong token and silently never fires.
    IERC20 public immutable rewardToken;

    /// @notice user => reward escrowed because the forwarding transfer failed.
    ///         Recoverable only by that user, via `claimForwarded()`.
    mapping(address => uint256) public unforwarded;

    /// @notice Σ unforwarded[*]. The FLOOR `rescueERC20` can never cross for
    ///         the reward token.
    uint256 public totalUnforwarded;

    event Migrated(uint256 userCount, uint256 totalAmount);

    /// @notice A `depositFor` settlement captured by this contract was
    ///         successfully forwarded on to the user it belonged to.
    event RewardForwarded(address indexed user, uint256 amount);

    /// @notice The forwarding transfer failed (revert or `false` return); the
    ///         amount is escrowed under `unforwarded[user]` instead.
    event RewardForwardFailed(address indexed user, uint256 amount);

    /// @notice A user withdrew their escrowed forwarding failure.
    event ForwardedClaimed(address indexed user, uint256 amount);

    constructor(
        INFTStakerMigratable _oldStaker,
        INFTStakerMigratable _newStaker,
        IERC1155 _stakedToken,
        uint256 _stakedId,
        IERC20 _rewardToken,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(_oldStaker) != address(0), "Migrator: zero old staker");
        require(address(_newStaker) != address(0), "Migrator: zero new staker");
        require(address(_stakedToken) != address(0), "Migrator: zero staked token");
        require(address(_oldStaker) != address(_newStaker), "Migrator: same staker");
        require(address(_rewardToken) != address(0), "Migrator: zero reward token");
        require(
            address(IStakerViews(address(_newStaker)).rewardToken()) == address(_rewardToken),
            "Migrator: reward token mismatch (new)"
        );
        require(
            address(IStakerViews(address(_oldStaker)).rewardToken()) == address(_rewardToken),
            "Migrator: reward token mismatch (old)"
        );
        oldStaker = _oldStaker;
        newStaker = _newStaker;
        stakedToken = _stakedToken;
        stakedId = _stakedId;
        rewardToken = _rewardToken;
    }

    /// @notice Engage migration on the old staker. Thin owner-only forwarder to
    ///         `INFTStakerMigratable.initiateMigration` (settles + freezes
    ///         emissions). Must be called exactly once BEFORE the first
    ///         `migrate` batch. The old staker reverts if already migrating, so
    ///         this is naturally idempotent-guarded.
    function initiateMigration() external onlyOwner {
        oldStaker.initiateMigration();
    }

    /// @notice Migrate a batch of users from the old staker to the new staker.
    /// @dev    Requires a prior `initiateMigration` (the old staker reverts
    ///         otherwise). Approves the new staker for exactly the pulled
    ///         total, then redeposits each non-zero user. Empty-batch (all
    ///         users already migrated / nothing staked) short-circuits with a
    ///         `Migrated(0, 0)` event and no approval.
    ///
    ///         Each redeposit is wrapped in the settlement-capture forwarding
    ///         sequence described in the contract NatSpec. `nonReentrant`
    ///         because the forward is a genuinely new external call inside a
    ///         loop; phUSD has no transfer callback today, but this pre-closes
    ///         the hole if the reward token is ever a callback-bearing one.
    /// @param  users The users to migrate (batched off-chain).
    function migrate(address[] calldata users) external onlyOwner nonReentrant {
        uint256[] memory amounts = oldStaker.batchMigrate(users);

        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (total == 0) {
            emit Migrated(0, 0);
            return;
        }

        // Scoped approval: the new staker pulls exactly `total` across the
        // redeposit loop. `setApprovalForAll` is the ERC1155 grant; it is
        // bounded by `total` because `depositFor` transfers exactly the
        // per-user amounts that sum to `total`.
        stakedToken.setApprovalForAll(address(newStaker), true);

        uint256 migratedCount;
        for (uint256 i = 0; i < users.length; i++) {
            if (amounts[i] > 0) {
                _depositForAndForward(users[i], amounts[i]);
                migratedCount++;
            }
        }

        // Revoke the operator approval — nothing should linger.
        stakedToken.setApprovalForAll(address(newStaker), false);

        emit Migrated(migratedCount, total);
    }

    /// @dev The settlement-capture forwarding sequence, factored out so it is
    ///      line-for-line identical to `InPlaceNFTStakerMigrator`'s (plan
    ///      decision D-6 — a divergence here is exactly the fork drift that
    ///      produced `pns20h1`).
    ///
    ///      `owed` is read on the DESTINATION staker (`newStaker`, the
    ///      `depositFor` target), not on `oldStaker`: the capture being bounded
    ///      is the target-side settlement.
    ///
    ///      `pre` is snapshotted PER ITERATION, not once before the loop —
    ///      earlier iterations forward value out and failed forwards leave
    ///      value in, so only a per-iteration delta is meaningful.
    function _depositForAndForward(address user, uint256 amount) private {
        uint256 owed = IStakerViews(address(newStaker)).pendingReward(user);
        uint256 pre = rewardToken.balanceOf(address(this));

        newStaker.depositFor(user, amount);

        uint256 captured = rewardToken.balanceOf(address(this)) - pre;
        require(captured <= owed, "Migrator: capture exceeds owed");

        if (captured > 0) {
            // Raw `transfer` inside `try`, NOT `safeTransfer`: SafeERC20
            // reverts rather than returning, which would defeat the `catch` on
            // non-reverting-false tokens. Both branches are handled.
            try rewardToken.transfer(user, captured) returns (bool ok) {
                if (ok) {
                    emit RewardForwarded(user, captured);
                } else {
                    unforwarded[user] += captured;
                    totalUnforwarded += captured;
                    emit RewardForwardFailed(user, captured);
                }
            } catch {
                unforwarded[user] += captured;
                totalUnforwarded += captured;
                emit RewardForwardFailed(user, captured);
            }
        }
    }

    /// @notice Permissionless, self-only recovery of reward escrowed by a
    ///         failed forward. No owner path can redirect it.
    /// @dev    Strict CEI under `nonReentrant`: the mapping is zeroed and
    ///         `totalUnforwarded` decremented BEFORE the transfer.
    function claimForwarded() external nonReentrant {
        uint256 amount = unforwarded[msg.sender];
        require(amount > 0, "Migrator: nothing unforwarded");

        unforwarded[msg.sender] = 0;
        totalUnforwarded -= amount;

        rewardToken.safeTransfer(msg.sender, amount);
        emit ForwardedClaimed(msg.sender, amount);
    }

    // ============================== RESCUE ==============================

    /// @notice Sweep a STRAY/DONATED ERC20 balance to `to`. For the reward
    ///         token the sweep is floored by `totalUnforwarded` (escrowed user
    ///         value the owner must never be able to reach); every other token
    ///         is an unconditional sweep.
    /// @dev    Owner-only. Without any rescue primitive at all, anything
    ///         delivered to this contract is PERMANENTLY stranded — that
    ///         permanence is what made `pns20h1` a High rather than a Medium,
    ///         so the primitive ships with the forwarding fix, not after it.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Migrator: zero recipient");
        if (address(token) == address(rewardToken)) {
            uint256 balance = rewardToken.balanceOf(address(this));
            uint256 surplus = balance - totalUnforwarded;
            require(amount <= surplus, "Migrator: cannot touch unforwarded");
        }
        token.safeTransfer(to, amount);
    }

    /// @notice Sweep STRAY ERC1155 to `to`. UNCONDITIONAL — no `stakedId`
    ///         floor.
    /// @dev    Owner-only. Unlike `InPlaceNFTStakerMigrator`, this migrator's
    ///         ERC1155 custody is INTRA-CALL ONLY: `batchMigrate` pulls the
    ///         stake in and `depositFor` pushes it out within the same
    ///         `migrate` transaction. There is no `totalParked` analogue and no
    ///         cross-transaction principal to protect, so a floor here would
    ///         guard nothing.
    function rescueERC1155(uint256 id, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Migrator: zero recipient");
        stakedToken.safeTransferFrom(address(this), to, id, amount, "");
    }
}
