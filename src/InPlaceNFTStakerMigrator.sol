// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {INFTStakerMigratable} from "./INFTStakerMigratable.sol";
import {IStakerViews} from "./IStakerViews.sol";

/// @title  InPlaceNFTStakerMigrator
/// @notice Swaps the `dispatcherIndex` / `dispatcherHook` wiring on a SINGLE
///         live `NFTStakerDepletion` in place, without a throwaway temp staker.
///         The nft-staking analogue of stable-staker's `InPlaceMigrator`
///         (which swaps a yield strategy); here the swapped dependency is the
///         dispatcher index + hook, the Uniboost equivalent — both are already
///         empty-pool-gated in the staker.
///
/// @dev    USE CASE — `setDispatcherIndex` (and `setStakedId`/`setNFTMinter`)
///         on the staker are empty-pool-only (`totalStaked == 0`). To rewire a
///         live pool the operator must evacuate every staker, reset the pool,
///         rewire, then put everyone back. This migrator parks the ERC1155
///         stake in its own custody across the reset and re-injects it into the
///         SAME staker once the new wiring is set.
///
///         CUSTODY — between `migrateOut` and `migrateIn` the migrator holds
///         the raw ERC1155 stake for every parked user (it implements
///         `ERC1155Holder`). This is a deliberate, SHORT, operator-orchestrated
///         trust window. The ONLY exits for parked stake are:
///           1. `migrateIn` -> `staker.depositFor(user, amount)` (the immutable
///              staker, crediting the original parked user), and
///           2. `claimTimedOut` -> ERC1155 back to the parked user themselves.
///         There is no owner path to redirect parked stake elsewhere. Earned
///         phUSD was already minted to each user at `migrateOut` (inside the
///         staker's `batchMigrate`), so the timeout hatch returns STAKE ONLY.
///
///         NO HAIRCUT / NO TOP-UP — the Uniboost staker moves exact ERC1155
///         amounts (no underwater yield strategy), so `depositFor` credits
///         exactly the parked amount and no surplus-funded top-up is needed.
///
///         SETTLEMENT-CAPTURE FORWARDING (audit `pns20h1`) — identical
///         mechanism to `NFTStakerMigrator`, deliberately line-for-line the
///         same (plan decision D-6). Some deployed stakers settle the incoming
///         user's re-accrued pending inside `depositFor` with `_safePay(...)`,
///         which pays `msg.sender` — i.e. THIS CONTRACT — rather than the user
///         (`NFTStakerDepletion.sol:756`); others settle correctly with
///         `_safePayTo(user, ...)` (`NFTStakerPriceScaledMigrateReady.sol:887`).
///         Those stakers are deployed and immutable, so `migrateIn` snapshots
///         `pendingReward(user)` and its own reward-token balance around every
///         `depositFor`, measures the capture as a balance delta, bounds it by
///         the pre-call `pendingReward`, and forwards it to the user. Against a
///         correct staker the capture is ZERO and no transfer occurs, so the
///         branch is self-disabling and version-agnostic.
///
///         THE BOUND IS A TRIPWIRE, NOT A HAIRCUT. `_syncBudget()` runs
///         `_updatePool()` before `dispatcherHook.pull()`, so the settled
///         accrual equals what `pendingReward(user)` projects at the same
///         timestamp. `require(captured <= owed)` fires only when foreign value
///         lands on the migrator mid-call (e.g. a dispatcher hook whose
///         `recipient` is mispointed here), which would otherwise be
///         misattributed to whichever user the loop is on.
///
///         ESCROW-ON-FAILURE. The forward is attempted inside `try`/`catch`; a
///         reverting or `false`-returning recipient credits `unforwarded[user]`
///         and emits `RewardForwardFailed` rather than taking the whole batch
///         down. The user recovers via the permissionless, self-only
///         `claimForwarded()`. `totalUnforwarded` floors `rescueERC20` for the
///         reward token, so no owner path can redirect escrowed value.
///
///         OFF-CHAIN RECONCILIATION CAVEAT. The staker still emits
///         `Claimed(user, pending)` before the forward completes, so a settled
///         payment can traverse TWO transfers (staker -> migrator -> user)
///         under ONE `Claimed` event. Indexers must join `Claimed` with
///         `RewardForwarded` / `RewardForwardFailed` to reconstruct the flow.
contract InPlaceNFTStakerMigrator is Ownable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    /// @notice The single live staker we are rewiring in place. Source AND
    ///         target. Immutable on purpose: an owner-mutable target would be a
    ///         drain vector defeating the timeout hatch.
    INFTStakerMigratable public immutable staker;

    /// @notice The ERC1155 stake token (must match the staker's `stakedToken`).
    IERC1155 public immutable stakedToken;

    /// @notice The ERC1155 stake ID (must match the staker's `stakedId`).
    uint256 public immutable stakedId;

    /// @notice Seconds after `migrateOut` before a parked user may invoke
    ///         `claimTimedOut`.
    uint256 public immutable migrationTimeout;

    /// @notice The reward token (phUSD) the staker emits. Supplied as a
    ///         constructor arg because `INFTStakerMigratable` does not expose
    ///         `rewardToken()`, and cross-checked against the staker's own
    ///         getter — a mismatch would mean the forwarding logic measures the
    ///         wrong token and silently never fires.
    IERC20 public immutable rewardToken;

    /// @notice user => parked ERC1155 stake currently held in custody.
    mapping(address => uint256) public parked;

    /// @notice user => `block.timestamp` at which the user was migrated out
    ///         (the timeout anchor).
    mapping(address => uint256) public migrationBegin;

    /// @notice Ordered list of users currently parked (re-injection / timeout
    ///         worklist). Maintained as a manual swap-remove set because the OZ
    ///         `EnumerableSet` requires solc ^0.8.24 while this submodule
    ///         targets 0.8.20.
    address[] private _parkedUsers;

    /// @notice user => 1-based index into `_parkedUsers` (0 == not present).
    mapping(address => uint256) private _parkedIndex;

    /// @notice Σ parked[*]. The FLOOR `rescueERC20` can never cross for the
    ///         staked token, and the running total `claimTimedOut`/`migrateIn`
    ///         decrement.
    uint256 public totalParked;

    /// @notice user => reward escrowed because the forwarding transfer failed.
    ///         Recoverable only by that user, via `claimForwarded()`.
    mapping(address => uint256) public unforwarded;

    /// @notice Σ unforwarded[*]. The FLOOR `rescueERC20` can never cross for
    ///         the reward token.
    uint256 public totalUnforwarded;

    /// @notice Lower bound on `migrationTimeout`: rejects 0/tiny values that
    ///         would open the hatch immediately and let an impatient user
    ///         front-run `migrateIn`.
    uint256 public constant MIN_TIMEOUT = 1 days;

    /// @notice Upper bound on `migrationTimeout` (30 days): rejects an
    ///         effectively-infinite value that would neuter the hatch.
    uint256 public constant MAX_TIMEOUT = 30 days;

    event MigratedOut(uint256 userCount, uint256 totalAmount);
    event MigratedIn(uint256 userCount, uint256 totalAmount);
    event TimedOutClaim(address indexed user, uint256 amount);

    /// @notice A `depositFor` settlement captured by this contract was
    ///         successfully forwarded on to the user it belonged to.
    event RewardForwarded(address indexed user, uint256 amount);

    /// @notice The forwarding transfer failed (revert or `false` return); the
    ///         amount is escrowed under `unforwarded[user]` instead.
    event RewardForwardFailed(address indexed user, uint256 amount);

    /// @notice A user withdrew their escrowed forwarding failure.
    event ForwardedClaimed(address indexed user, uint256 amount);

    constructor(
        INFTStakerMigratable _staker,
        IERC1155 _stakedToken,
        uint256 _stakedId,
        uint256 _migrationTimeout,
        IERC20 _rewardToken,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(_staker) != address(0), "InPlace: zero staker");
        require(address(_stakedToken) != address(0), "InPlace: zero staked token");
        require(_migrationTimeout >= MIN_TIMEOUT && _migrationTimeout <= MAX_TIMEOUT, "InPlace: timeout out of bounds");
        require(address(_rewardToken) != address(0), "InPlace: zero reward token");
        require(
            address(IStakerViews(address(_staker)).rewardToken()) == address(_rewardToken),
            "InPlace: reward token mismatch"
        );
        staker = _staker;
        stakedToken = _stakedToken;
        stakedId = _stakedId;
        migrationTimeout = _migrationTimeout;
        rewardToken = _rewardToken;
    }

    // ============================== INTERNAL SET ==============================

    /// @dev Add `user` to the parked set if absent (idempotent).
    function _addParked(address user) private {
        if (_parkedIndex[user] == 0) {
            _parkedUsers.push(user);
            _parkedIndex[user] = _parkedUsers.length; // 1-based
        }
    }

    /// @dev Swap-remove `user` from the parked set if present (idempotent).
    function _removeParked(address user) private {
        uint256 idx = _parkedIndex[user];
        if (idx == 0) return;
        uint256 last = _parkedUsers.length;
        if (idx != last) {
            address moved = _parkedUsers[last - 1];
            _parkedUsers[idx - 1] = moved;
            _parkedIndex[moved] = idx;
        }
        _parkedUsers.pop();
        _parkedIndex[user] = 0;
    }

    // ============================== MIGRATION (OUT) ==============================

    /// @notice Engage migration on the staker. Thin owner-only forwarder to
    ///         `INFTStakerMigratable.initiateMigration` (settles + freezes
    ///         emissions). Call exactly once BEFORE the first `migrateOut`.
    function initiateMigration() external onlyOwner {
        staker.initiateMigration();
    }

    /// @notice Drain a batch of users out of the staker and PARK their ERC1155
    ///         stake in custody. The staker settles + mints each user's frozen
    ///         earned phUSD during `batchMigrate` and transfers the aggregate
    ///         ERC1155 to this contract; we record it per-user.
    /// @dev    Requires a prior `initiateMigration`. Idempotent: `batchMigrate`
    ///         zeroes the source position, so a re-run returns 0 for an
    ///         already-migrated user (no double-park).
    /// @param  users The users to drain out (batched off-chain).
    function migrateOut(address[] calldata users) external onlyOwner nonReentrant {
        uint256[] memory amounts = staker.batchMigrate(users);

        uint256 total;
        uint256 count;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 amt = amounts[i];
            if (amt > 0) {
                parked[users[i]] += amt;
                migrationBegin[users[i]] = block.timestamp;
                _addParked(users[i]);
                totalParked += amt;
                total += amt;
                count++;
            }
        }

        emit MigratedOut(count, total);
    }

    // ============================== MIGRATION (IN) ==============================

    /// @notice Re-inject a slice `[start, end)` of currently-parked users back
    ///         into the SAME staker, crediting each the exact ERC1155 stake that
    ///         was parked for them.
    /// @dev    Re-injection goes ONLY into the immutable `staker`. Snapshots the
    ///         slice into memory FIRST, because removing users from the set
    ///         mid-loop shifts live indices. CEI under `nonReentrant`: each
    ///         user's `parked` is zeroed BEFORE its `depositFor`. Skips
    ///         already-claimed/empty users with no revert and no double pay.
    ///         The staker must be back in `Active` (owner ran
    ///         `finalizeAndReset` + the rewire) for `depositFor` to succeed.
    /// @param  start Inclusive start index into the parked-user set.
    /// @param  end   Exclusive end index (clamped to the set length).
    function migrateIn(uint256 start, uint256 end) external onlyOwner nonReentrant {
        uint256 len = _parkedUsers.length;
        if (end > len) {
            end = len;
        }
        require(start <= end, "InPlace: bad range");

        // Snapshot the slice FIRST: removing from the set mid-loop shifts
        // live indices.
        uint256 sliceLen = end - start;
        address[] memory slice = new address[](sliceLen);
        for (uint256 i = 0; i < sliceLen; i++) {
            slice[i] = _parkedUsers[start + i];
        }

        // Scoped operator approval for the staked token; the staker pulls
        // exactly the parked amounts across the loop. Set only if there is
        // parked stake to re-inject.
        if (totalParked > 0) {
            stakedToken.setApprovalForAll(address(staker), true);
        }

        uint256 total;
        uint256 count;
        for (uint256 i = 0; i < sliceLen; i++) {
            address user = slice[i];
            uint256 amt = parked[user];
            if (amt == 0) {
                continue;
            }
            // Effects BEFORE interaction (CEI): zero parked state first.
            parked[user] = 0;
            delete migrationBegin[user];
            totalParked -= amt;
            _removeParked(user);
            total += amt;
            count++;

            // The only owner-driven exit for parked stake: back into the
            // immutable staker, crediting the original user — wrapped in the
            // settlement-capture forwarding sequence.
            _depositForAndForward(user, amt);
        }

        stakedToken.setApprovalForAll(address(staker), false);

        emit MigratedIn(count, total);
    }

    /// @dev The settlement-capture forwarding sequence. Line-for-line identical
    ///      to `NFTStakerMigrator._depositForAndForward` (plan decision D-6 — a
    ///      divergence here is exactly the fork drift that produced `pns20h1`).
    ///      Source and target are the same contract here, so `owed` is read on
    ///      `staker`.
    ///
    ///      `pre` is snapshotted PER ITERATION, not once before the loop —
    ///      earlier iterations forward value out and failed forwards leave
    ///      value in, so only a per-iteration delta is meaningful.
    function _depositForAndForward(address user, uint256 amount) private {
        uint256 owed = IStakerViews(address(staker)).pendingReward(user);
        uint256 pre = rewardToken.balanceOf(address(this));

        staker.depositFor(user, amount);

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
    /// @dev    Strict CEI under `nonReentrant`, modelled on `claimTimedOut`:
    ///         the mapping is zeroed and `totalUnforwarded` decremented BEFORE
    ///         the transfer.
    function claimForwarded() external nonReentrant {
        uint256 amount = unforwarded[msg.sender];
        require(amount > 0, "InPlace: nothing unforwarded");

        unforwarded[msg.sender] = 0;
        totalUnforwarded -= amount;

        rewardToken.safeTransfer(msg.sender, amount);
        emit ForwardedClaimed(msg.sender, amount);
    }

    // ============================== TIMEOUT ESCAPE HATCH ==============================

    /// @notice Permissionless, self-only escape hatch: a parked user reclaims
    ///         THEIR OWN ERC1155 stake once `migrationTimeout` has elapsed since
    ///         their `migrateOut`.
    /// @dev    Returns STAKE ONLY — earned phUSD was already minted to the user
    ///         at `migrateOut`. Strict CEI under `nonReentrant`: all state is
    ///         cleared BEFORE the transfer.
    function claimTimedOut() external nonReentrant {
        uint256 amount = parked[msg.sender];
        require(amount > 0, "InPlace: nothing parked");
        require(block.timestamp >= migrationBegin[msg.sender] + migrationTimeout, "InPlace: timeout not elapsed");

        // Effects BEFORE interaction (CEI).
        parked[msg.sender] = 0;
        delete migrationBegin[msg.sender];
        totalParked -= amount;
        _removeParked(msg.sender);

        // The only user-driven exit for parked stake: to the user themselves.
        stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, amount, "");
        emit TimedOutClaim(msg.sender, amount);
    }

    // ============================== RESCUE ==============================

    /// @notice Sweep a STRAY/DONATED ERC20 balance to `to`. Unconditional for
    ///         every token EXCEPT the reward token, where the sweep is floored
    ///         by `totalUnforwarded` — reward escrowed by a failed forward
    ///         belongs to its user and must be unreachable by the owner.
    /// @dev    Owner-only. Parked principal is ERC1155 and therefore
    ///         structurally untouchable by this function; the reward-token
    ///         floor is the ERC20 analogue of the `totalParked` floor
    ///         `rescueERC1155` applies to the staked id.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "InPlace: zero recipient");
        if (address(token) == address(rewardToken)) {
            uint256 balance = rewardToken.balanceOf(address(this));
            uint256 surplus = balance - totalUnforwarded;
            require(amount <= surplus, "InPlace: cannot touch unforwarded");
        }
        token.safeTransfer(to, amount);
    }

    /// @notice Sweep STRAY ERC1155 of an UNPARKED id, or surplus of the staked
    ///         id strictly above the `totalParked` floor, to `to`. The floor is
    ///         what preserves the no-touch-parked-principal guarantee even
    ///         against the owner.
    /// @dev    Owner-only. For `id == stakedId`, `amount` must be <= balance -
    ///         totalParked (the donated surplus); any amount dipping into
    ///         `totalParked` reverts. For any other id, the full balance is
    ///         free (never parked here).
    function rescueERC1155(uint256 id, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "InPlace: zero recipient");
        if (id == stakedId) {
            uint256 balance = stakedToken.balanceOf(address(this), stakedId);
            uint256 surplus = balance - totalParked;
            require(amount <= surplus, "InPlace: cannot touch parked principal");
        }
        stakedToken.safeTransferFrom(address(this), to, id, amount, "");
    }

    // ============================== VIEWS ==============================

    /// @notice Number of users currently parked.
    function parkedUserCount() external view returns (uint256) {
        return _parkedUsers.length;
    }

    /// @notice Page through the currently-parked users (for `migrateIn` slices).
    function parkedUsersRange(uint256 start, uint256 end) external view returns (address[] memory out) {
        uint256 len = _parkedUsers.length;
        if (end > len) {
            end = len;
        }
        if (start > end) {
            start = end;
        }
        out = new address[](end - start);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = _parkedUsers[start + i];
        }
    }

    /// @notice Timestamp at/after which `user` may `claimTimedOut` (0 if not
    ///         parked).
    function claimableAt(address user) external view returns (uint256) {
        uint256 begin = migrationBegin[user];
        if (begin == 0) {
            return 0;
        }
        return begin + migrationTimeout;
    }
}
