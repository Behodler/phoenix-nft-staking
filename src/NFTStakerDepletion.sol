// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {IUniboostMintDebtHook} from "yield-claim-nft/interfaces/IUniboostMintDebtHook.sol";
import {INFTSupply} from "./INFTSupply.sol";
import {INFTStakerMigratable} from "./INFTStakerMigratable.sol";

/// @title  NFTStakerDepletion
/// @notice Depletion-window standalone copy of `NFTStaker`. This contract is a
///         HAND-MAINTAINED copy of `src/NFTStaker.sol` that replaces the
///         owner-set **targetAPY** emission model with an owner-set
///         **depletion-window** model (modelled on phlimbo's
///         `depletionDuration`). The owner sets the window (in months); the
///         per-second emission rate is DERIVED as `budget / windowSeconds`,
///         inverting the original where the rate is set (via APY × notional)
///         and the window is derived (`budget / rate`).
///
///         WHY A COPY: the nft-staking repo deliberately avoids a shared base
///         contract (see `NFTStakerPriceScaled`). The live audited `NFTStaker`
///         stays byte-for-byte untouched; this variant is deployed alongside
///         it for the Uniboost dispatcher.
///
///         MAINTENANCE COUPLING: this is a HAND-MAINTAINED copy of
///         `NFTStaker`. Any future fix or audit change to `NFTStaker` is NOT
///         automatically inherited here and MUST be mirrored manually. The
///         intended deltas vs `NFTStaker` are:
///           1. Hook field typed `IUniboostMintDebtHook` (not
///              `IBalancerPoolerMintDebtHook`) — surface is identical
///              (`mintDebt()` / `pull()`); ties this staker to the Uniboost
///              mint-debt hook.
///           2. `targetAPY` / `MAX_TARGET_APY` / `APY_PRECISION` REMOVED;
///              replaced by `depletionWindowMonths`, `SECONDS_PER_MONTH`, and
///              `MAX_DEPLETION_MONTHS`.
///           3. `setTargetAPY` -> `setDepletionWindow(uint256 months)` with a
///              `1 <= months <= MAX_DEPLETION_MONTHS` bound and a
///              `DepletionWindowChanged` event.
///           4. `_recomputeSchedule` rewritten: `rewardRate = budget /
///              windowSeconds`, `windowEnd = now + windowSeconds`,
///              `lastRewardTime = now`. The dispatcher-price / notional math
///              (`latestPrice`, `S`, `F`) is DROPPED — the rate no longer
///              depends on price. `dispatcherIndex` / `nftMinter` are RETAINED
///              purely as identity/wiring parity.
///           5. New owner-only `rescueERC20` (with the rewardToken invariant
///              guard), `Rescued` event, and `Rescue__ZeroRecipient` error.
///           6. `SECONDS_PER_YEAR` retained only as documentation of the
///              `SECONDS_PER_MONTH = 365 days / 12` derivation (12 months == 1
///              APY-year); it is no longer used by the rate path.
///
///         Masterchef-style staking pool for a single ERC1155 token ID.
///         Stakers deposit ERC1155 units of `stakedId` and earn per-second
///         emissions of `rewardToken` (phUSD) that drain `rewardBudget` over
///         exactly `depletionWindowMonths`. The strong invariant
///         `balance == rewardBudget + committedDebt` and floor-rounding always
///         in the protocol's favour are preserved from `NFTStaker`.
contract NFTStakerDepletion is Ownable, Pausable, ReentrancyGuard, ERC1155Holder, IPausable, INFTStakerMigratable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant ACC_PRECISION = 1e18;

    /// @notice Seconds in a financial year (365 days). Retained from
    ///         `NFTStaker` only as the basis for `SECONDS_PER_MONTH`; it is
    ///         NOT used by the depletion-window rate path.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Seconds in a depletion-window "month". Chosen as
    ///         `365 days / 12` (= 2,628,000s) for consistency with
    ///         `SECONDS_PER_YEAR = 365 days`: a 12-month window is exactly one
    ///         APY-year. Deliberately NOT the 30-day or 30.44-day average.
    uint256 public constant SECONDS_PER_MONTH = 365 days / 12;

    /// @notice Sanity ceiling for `depletionWindowMonths` (120 = 10 years). A
    ///         longer window is almost certainly an operator error and risks
    ///         flooring the rate to zero for any realistic budget.
    uint256 public constant MAX_DEPLETION_MONTHS = 120;

    // ---------------------------------------------------------------------
    // Config (immutable)
    // ---------------------------------------------------------------------

    IERC1155 public immutable stakedToken;
    IERC20 public immutable rewardToken;

    // ---------------------------------------------------------------------
    // Config (mutable, owner-controlled)
    // ---------------------------------------------------------------------

    /// @notice The ERC1155 token ID currently being staked. Mutable but only
    ///         changeable while `totalStaked == 0`.
    uint256 public stakedId;

    /// @notice Uniboost dispatcher hook supplying phUSD via `pull()`. Set
    ///         post-deploy. NOTE: `UniboostMintDebtHook.pull()` is
    ///         `onlyOwnerOrRecipient`, so this staker must be set as the
    ///         hook's `recipient` (or owner) for `pull()` to succeed.
    IUniboostMintDebtHook public dispatcherHook;

    /// @notice Address authorised to pause/unpause via the global pauser.
    address public pauser;

    /// @notice Re-typed reference to NFTMinterV2 for supply and configs
    ///         reads. Retained for identity/wiring parity with the other
    ///         stakers even though the depletion rate no longer consumes the
    ///         dispatcher price. In production this is the same contract as
    ///         `stakedToken`.
    INFTSupply public nftMinter;

    /// @notice Index into `nftMinter.configs` identifying the dispatcher this
    ///         staker serves. Retained purely as IDENTITY (which dispatcher
    ///         this staker is tied to) — the depletion rate is
    ///         `budget / window`, independent of `configs(dispatcherIndex)`.
    ///         Owner-settable only when `totalStaked == 0`.
    uint256 public dispatcherIndex;

    /// @notice Owner-set depletion window in MONTHS. The reward budget drains
    ///         linearly to (floor) dust over `depletionWindowMonths *
    ///         SECONDS_PER_MONTH`. Replaces `NFTStaker.targetAPY`. Bounded
    ///         `1 <= months <= MAX_DEPLETION_MONTHS` (zero is disallowed: it
    ///         would divide by zero; pause emissions via `pause()` instead).
    uint256 public depletionWindowMonths;

    // ---------------------------------------------------------------------
    // Schedule state
    // ---------------------------------------------------------------------

    /// @notice Timestamp at which the current schedule depletes the budget at
    ///         `rewardRate`. Set to `now + depletionWindowMonths *
    ///         SECONDS_PER_MONTH` on every recompute — the window is now the
    ///         INPUT (owner-set), not the derived runway.
    uint256 public windowEnd;

    /// @notice Per-second phUSD emissions. Derived as
    ///         `rewardBudget / windowSeconds` on every recompute. UNSCALED
    ///         (no PRECISION factor) to match the audited `NFTStaker` accrual
    ///         machinery and the `balance == rewardBudget + committedDebt`
    ///         invariant. Recomputed ONLY in `setDepletionWindow` /
    ///         `_syncBudget` / `_recomputeSchedule`, never inside per-
    ///         interaction accrual (avoids phlimbo's V1 rate-drift bug).
    uint256 public rewardRate;

    /// @notice Value budgeted for the current schedule, equal to
    ///         `V - committedDebt` at the most recent recompute (where
    ///         `V = balance + mintDebt`). Decreases as `_updatePool`
    ///         settles accrual.
    uint256 public rewardBudget;

    /// @notice Per-share-baked, unpaid emissions: the cumulative phUSD that
    ///         `_updatePool` has moved from `rewardBudget` into
    ///         `accRewardPerShare`, minus the cumulative phUSD that
    ///         `_safePay` has actually paid out. Maintained as O(1) state to
    ///         preserve the strong invariant
    ///         `balance == rewardBudget + committedDebt` at all times — see
    ///         `CLAUDE.md` ("Solvency (always)") and audit fix M-01.
    uint256 public committedDebt;

    // ---------------------------------------------------------------------
    // Accrual state
    // ---------------------------------------------------------------------

    uint256 public lastRewardTime;
    uint256 public totalStaked;
    uint256 public accRewardPerShare;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    mapping(address => UserInfo) public users;

    // ---------------------------------------------------------------------
    // Migration state
    // ---------------------------------------------------------------------

    /// @notice Lifecycle gate for the stable-staker-style migration flow.
    ///         `Active` is the normal operating state (stake/unstake/claim and
    ///         `depositFor` are permitted). `Migrating` is the frozen
    ///         settle-and-evacuate state engaged by `initiateMigration`:
    ///         emissions are settled to that block and frozen, and the only
    ///         exits are the permissioned `batchMigrate` and the permissionless
    ///         `userMigrate`. The only way back to `Active` is
    ///         `finalizeAndReset`, gated on a fully-drained pool.
    enum PoolState {
        Active,
        Migrating
    }

    /// @notice Current migration lifecycle state. Defaults to `Active`.
    PoolState public poolState;

    /// @notice Address authorised to drive the migration primitives
    ///         (`initiateMigration`, `batchMigrate`, `depositFor`). Set by the
    ///         owner to the relevant orchestrator (`NFTStakerMigrator` /
    ///         `InPlaceNFTStakerMigrator`).
    address public migrator;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice `rescueERC20` recipient was the zero address.
    error Rescue__ZeroRecipient();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    /// @dev Emitted when a `pull()` from the dispatcher hook yields a
    ///      non-zero inflow.
    event Pulled(uint256 inflow, uint256 newBudget);
    /// @dev Emitted on a successful owner top-up.
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    /// @dev Replaces `NFTStaker.TargetAPYChanged`: emitted when the owner
    ///      changes the depletion window (in months).
    event DepletionWindowChanged(uint256 previous, uint256 next);
    event DispatcherIndexChanged(uint256 previous, uint256 next);
    event NFTMinterChanged(address indexed previous, address indexed next);
    /// @dev Emitted whenever `_recomputeSchedule` runs. Fields are the
    ///      depletion window in seconds (the basis the rate is sized against),
    ///      the `availableValue` available for emissions (`V - committedDebt`),
    ///      the new per-second rate, and the new windowEnd timestamp. The
    ///      first field name (`totalNFTValue`) is preserved from the
    ///      `NFTStaker` schema for off-chain consumer compatibility, but in
    ///      this variant it carries `windowSeconds` rather than a notional.
    event ScheduleRecomputed(uint256 totalNFTValue, uint256 availableValue, uint256 newRate, uint256 newWindowEnd);
    /// @dev Emitted on a successful `rescueERC20`. Mirrors
    ///      `BatchNFTMinter.Rescued`.
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @dev Emitted when the owner sets/rotates the `migrator`.
    event MigratorSet(address indexed previous, address indexed next);
    /// @dev Emitted when `initiateMigration` freezes the pool.
    event MigrationInitiated(uint256 totalStaked);
    /// @dev Emitted per user evacuated by `batchMigrate`: their staked ERC1155
    ///      amount (moved to the migrator) and the pending phUSD reward settled
    ///      to them.
    event MigratedOut(address indexed user, uint256 amount, uint256 reward);
    /// @dev Emitted on a permissionless `userMigrate` self-exit: the staked
    ///      ERC1155 amount returned to the user and the pending phUSD settled.
    event UserMigrated(address indexed user, uint256 amount, uint256 reward);
    /// @dev Emitted per user credited by `depositFor` on the receiving staker.
    event DepositedFor(address indexed user, uint256 amount);
    /// @dev Emitted when `finalizeAndReset` returns a drained pool to `Active`.
    event PoolReset();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyPauser() {
        require(msg.sender == pauser, "NFTStaker: caller is not pauser");
        _;
    }

    modifier onlyMigrator() {
        require(msg.sender == migrator, "NFTStaker: caller is not migrator");
        _;
    }

    constructor(
        IERC1155 _stakedToken,
        uint256 _stakedId,
        IERC20 _rewardToken,
        address _initialOwner,
        INFTSupply _nftMinter,
        uint256 _dispatcherIndex
    ) Ownable(_initialOwner) {
        require(address(_stakedToken) != address(0), "NFTStaker: zero staked token");
        require(address(_rewardToken) != address(0), "NFTStaker: zero reward token");
        require(address(_nftMinter) != address(0), "NFTStaker: zero nft minter");
        stakedToken = _stakedToken;
        stakedId = _stakedId;
        rewardToken = _rewardToken;
        nftMinter = _nftMinter;
        dispatcherIndex = _dispatcherIndex;
    }

    // ---------------------------------------------------------------------
    // Owner / pauser admin
    // ---------------------------------------------------------------------

    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Set/rotate the migration orchestrator authorised to call the
    ///         `onlyMigrator` primitives. Setting to `address(0)` disables
    ///         migration. No empty-pool gate — the migrator must be wired
    ///         before `initiateMigration` is called.
    function setMigrator(address newMigrator) external onlyOwner {
        emit MigratorSet(migrator, newMigrator);
        migrator = newMigrator;
    }

    function pause() external onlyPauser {
        _pause();
    }

    function unpause() external onlyPauser {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Owner setters
    // ---------------------------------------------------------------------

    function setDispatcherHook(IUniboostMintDebtHook newHook) external onlyOwner {
        emit DispatcherHookChanged(address(dispatcherHook), address(newHook));
        dispatcherHook = newHook;
    }

    function setStakedId(uint256 newId) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit StakedIdChanged(stakedId, newId);
        stakedId = newId;
    }

    /// @notice Update the dispatcher index (identity only). Guarded by
    ///         `totalStaked == 0` for parity with the other stakers.
    function setDispatcherIndex(uint256 newIndex) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit DispatcherIndexChanged(dispatcherIndex, newIndex);
        dispatcherIndex = newIndex;
        _recomputeSchedule();
    }

    /// @notice Swap the `nftMinter` reference (identity only). Guarded by
    ///         `totalStaked == 0`.
    function setNFTMinter(INFTSupply newMinter) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        require(address(newMinter) != address(0), "NFTStaker: zero nft minter");
        emit NFTMinterChanged(address(nftMinter), address(newMinter));
        nftMinter = newMinter;
        _recomputeSchedule();
    }

    /// @notice Set the depletion window (in months). Settles in-flight accrual
    ///         at the OLD rate before mutating so existing stakers are paid
    ///         what they earned under the prior schedule, then recomputes the
    ///         rate from the new window. Replaces `NFTStaker.setTargetAPY`.
    /// @param  months `1 <= months <= MAX_DEPLETION_MONTHS`. Zero is rejected
    ///         (division by zero); to pause emissions use `pause()`.
    function setDepletionWindow(uint256 months) external onlyOwner {
        require(months >= 1 && months <= MAX_DEPLETION_MONTHS, "NFTStaker: window out of range");
        _updatePool();
        emit DepletionWindowChanged(depletionWindowMonths, months);
        depletionWindowMonths = months;
        _recomputeSchedule();
    }

    /// @notice Owner-only refill of the reward budget. Transfers `amount`
    ///         phUSD into the contract then recomputes the schedule. Does not
    ///         call `_syncBudget`, preserving the dispatcher-hook-independence
    ///         escape property.
    /// @param  amount phUSD units to inject. Must be nonzero.
    function topUp(uint256 amount) external onlyOwner {
        require(amount > 0, "NFTStaker: zero topUp");
        _updatePool();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        _recomputeSchedule();
        emit ToppedUp(msg.sender, amount, rewardBudget);
    }

    /// @notice Owner-only manual trigger of `_syncBudget`.
    function pullAndRefresh() external onlyOwner {
        _syncBudget();
    }

    /// @notice Owner-only recovery of an arbitrary ERC20. Modelled on
    ///         `BatchNFTMinter.rescueERC20`: zero-recipient guard, explicit
    ///         amount, `safeTransfer`, `Rescued` event, callable while paused.
    ///
    ///         Non-reward tokens transfer freely. If `token == rewardToken`,
    ///         the call is GUARDED so it cannot strip owed/committed reward:
    ///         settle accrual (`_updatePool`), require the post-transfer
    ///         balance still covers `committedDebt`, then `_recomputeSchedule`
    ///         so `rewardBudget` / `rewardRate` / `windowEnd` re-derive from
    ///         the reduced balance. This lets the owner recover genuine
    ///         surplus without desyncing the
    ///         `balance == rewardBudget + committedDebt` invariant.
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Rescue__ZeroRecipient();
        if (address(token) == address(rewardToken)) {
            _updatePool();
            token.safeTransfer(to, amount);
            require(rewardToken.balanceOf(address(this)) >= committedDebt, "NFTStaker: rescue breaches committedDebt");
            _recomputeSchedule();
        } else {
            token.safeTransfer(to, amount);
        }
        emit Rescued(address(token), to, amount);
    }

    // ---------------------------------------------------------------------
    // Internal funding mechanics
    // ---------------------------------------------------------------------

    /// @dev Materialises pending mint debt as phUSD via `pull()`, then
    ///      recomputes the emission schedule against the new balance. If
    ///      the hook is unset, behaves like a pure recompute (still useful
    ///      after a state-changing config setter).
    function _syncBudget() internal {
        _updatePool();                                 // always: settle accrual
        if (address(dispatcherHook) == address(0)) {
            return;                                    // no hook → no pull → no budget change → no recompute
        }
        uint256 pre = rewardToken.balanceOf(address(this));
        dispatcherHook.pull();
        uint256 inflow = rewardToken.balanceOf(address(this)) - pre;
        if (inflow > 0) {                              // new NFT minted → budget grew → restart window (intended)
            _recomputeSchedule();
            emit Pulled(inflow, rewardBudget);
        }
    }

    /// @dev Settles per-share accrual from `lastRewardTime` up to
    ///      `min(now, windowEnd)` under the current `rewardRate`. Moves the
    ///      accrued amount out of `rewardBudget` and into `committedDebt`
    ///      (preserving `balance == rewardBudget + committedDebt`), then
    ///      bakes it into `accRewardPerShare`. Clamps the move to the
    ///      remaining `rewardBudget` to guarantee clean depletion.
    ///
    ///      CRITICAL: does NOT recompute `rewardRate` here — the rate is only
    ///      re-derived in `setDepletionWindow` / `_syncBudget` /
    ///      `_recomputeSchedule`. Recomputing the rate inside per-interaction
    ///      accrual was phlimbo's V1 bug.
    function _updatePool() internal {
        // While Migrating, emissions are frozen: every user's pending phUSD is
        // fixed at the `initiateMigration` snapshot and minted in full on their
        // exit. Fast-forward `lastRewardTime` so the frozen gap is never
        // retro-accrued once the pool is revived.
        if (poolState == PoolState.Migrating) {
            lastRewardTime = block.timestamp;
            return;
        }
        if (block.timestamp <= lastRewardTime) return;
        if (totalStaked == 0) {
            lastRewardTime = block.timestamp;
            return;
        }
        uint256 end = block.timestamp < windowEnd ? block.timestamp : windowEnd;
        uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
        uint256 reward = elapsed * rewardRate;
        if (reward > rewardBudget) reward = rewardBudget;
        if (reward > 0) {
            rewardBudget -= reward;
            committedDebt += reward;
            accRewardPerShare += (reward * ACC_PRECISION) / totalStaked;
        }
        lastRewardTime = block.timestamp;
    }

    /// @dev Closed-form recompute of the depletion-window emission schedule.
    ///      Inverts `NFTStaker._recomputeSchedule`: the owner sets the window,
    ///      and the rate is DERIVED from `budget / windowSeconds`.
    ///
    ///      Math:
    ///        windowSeconds = depletionWindowMonths * SECONDS_PER_MONTH
    ///        V             = balance + mintDebt
    ///        budget        = V - committedDebt          // M-01
    ///        rewardRate    = budget / windowSeconds     // floor; UNSCALED
    ///        windowEnd     = now + windowSeconds
    ///        lastRewardTime = now
    ///
    ///      The dispatcher-price / notional math (`latestPrice`, `S`, `F`) of
    ///      `NFTStaker` is DROPPED — the depletion rate depends only on
    ///      `budget / window`, not on APY × notional. `dispatcherIndex` /
    ///      `nftMinter` are retained purely as identity.
    ///
    ///      Edge cases:
    ///        depletionWindowMonths == 0  -> rate 0, windowEnd = now (the
    ///                                       unconfigured pre-setter state;
    ///                                       `setDepletionWindow` forbids 0).
    ///        budget < windowSeconds      -> FLOOR-TO-ZERO: a tiny budget over
    ///                                       a multi-month window floors the
    ///                                       per-second rate to 0. This is
    ///                                       ACCEPTABLE and protocol-
    ///                                       favourable: the budget simply
    ///                                       drips nothing rather than over-
    ///                                       promising; it is recovered on the
    ///                                       next recompute once the budget
    ///                                       grows or the window shrinks. Kept
    ///                                       unscaled (no PRECISION factor) to
    ///                                       minimise divergence from the
    ///                                       audited `NFTStaker` accrual.
    ///
    ///      Rounding: `budget / windowSeconds` floors, shaving at most
    ///      `windowSeconds - 1` wei of emissions over the full window in the
    ///      protocol's favour. DO NOT flip to ceiling rounding — that would
    ///      let users draw against rewards the contract has not budgeted for.
    function _recomputeSchedule() internal {
        uint256 windowSeconds = depletionWindowMonths * SECONDS_PER_MONTH;

        uint256 V = rewardToken.balanceOf(address(this));
        if (address(dispatcherHook) != address(0)) {
            V += dispatcherHook.mintDebt();
        }

        // Strip already-committed accrual from V before sizing the next
        // budget (M-01). Clamp at zero to keep recompute non-reverting if
        // hook misbehaviour ever drives V below committedDebt.
        uint256 budget = V > committedDebt ? V - committedDebt : 0;

        uint256 newRate = (windowSeconds == 0) ? 0 : budget / windowSeconds;

        rewardRate = newRate;
        rewardBudget = budget;
        windowEnd = block.timestamp + windowSeconds;
        lastRewardTime = block.timestamp;

        emit ScheduleRecomputed(windowSeconds, budget, newRate, windowEnd);
    }

    // ---------------------------------------------------------------------
    // User entrypoints
    // ---------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "NFTStaker: zero stake");
        // Head: settle accrual at the OLD rate (preserves "late stakers never
        // get retroactive rewards"). Sweeps mint debt and recomputes too; we
        // re-recompute at the tail.
        _syncBudget();
        UserInfo storage user = users[msg.sender];
        if (user.amount > 0) {
            uint256 pending = (user.amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
            if (pending > 0) {
                pending = _safePay(pending);
                if (pending > 0) emit Claimed(msg.sender, pending);
            }
        }
        stakedToken.safeTransferFrom(msg.sender, address(this), stakedId, amount, "");
        user.amount += amount;
        totalStaked += amount;
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "NFTStaker: zero unstake");
        UserInfo storage user = users[msg.sender];
        require(user.amount >= amount, "NFTStaker: insufficient stake");
        _syncBudget();
        uint256 pending = (user.amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        if (pending > 0) {
            pending = _safePay(pending);
            if (pending > 0) emit Claimed(msg.sender, pending);
        }
        user.amount -= amount;
        totalStaked -= amount;
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
        stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, amount, "");
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant whenNotPaused {
        _syncBudget();
        UserInfo storage user = users[msg.sender];
        uint256 pending = (user.amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        if (pending > 0) {
            uint256 paid = _safePay(pending);
            if (paid > 0) emit Claimed(msg.sender, paid);
        }
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
    }

    /// @dev Transfers `amount` of rewardToken to msg.sender. Reverts if the
    ///      on-chain balance is insufficient (no silent forfeiture). After
    ///      the transfer succeeds, decrement `(committedDebt + rewardBudget)`
    ///      by `amount` to preserve the strong invariant
    ///      `balance == rewardBudget + committedDebt`.
    function _safePay(uint256 amount) internal returns (uint256) {
        return _safePayTo(msg.sender, amount);
    }

    /// @dev `_safePay` variant that pays an explicit `account` rather than
    ///      `msg.sender`. Needed by the migration paths, where `batchMigrate`'s
    ///      `msg.sender` is the migrator but the settled phUSD reward must be
    ///      paid to the migrating user. Solvency accounting is identical:
    ///      decrement `(committedDebt + rewardBudget)` by `amount` to preserve
    ///      `balance == rewardBudget + committedDebt`.
    function _safePayTo(address account, uint256 amount) internal returns (uint256) {
        require(rewardToken.balanceOf(address(this)) >= amount, "NFTStaker: insufficient reward balance");
        if (amount > 0) {
            rewardToken.safeTransfer(account, amount);
            if (amount > committedDebt) {
                rewardBudget -= (amount - committedDebt);
                committedDebt = 0;
            } else {
                committedDebt -= amount;
            }
        }
        return amount;
    }

    /// @notice Withdraw the caller's full principal in a single ERC1155
    ///         transfer, forfeiting any pending reward. Callable while
    ///         paused and does NOT call `_syncBudget` / `_updatePool`, so
    ///         a broken dispatcher hook, NFT minter, or recompute path can
    ///         never trap principal. Standard masterchef escape hatch.
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = users[msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "NFTStaker: nothing to withdraw");
        uint256 pending = (amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;
        if (pending > 0) {
            uint256 forfeit = pending > committedDebt ? committedDebt : pending;
            committedDebt -= forfeit;
            rewardBudget += forfeit;
        }
        stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, amount, "");
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Migration primitives (onlyMigrator / onlyOwner) — stable-staker analogue
    // ---------------------------------------------------------------------

    /// @notice Engage migration: settle in-flight accrual, sweep mint debt, and
    ///         freeze emissions by flipping `poolState` to `Migrating`. Unlike
    ///         stable-staker's `initiateMigration` there is NO yield-strategy
    ///         unwind — the Uniboost staker's budget is idle rewardToken + hook
    ///         mint-debt, so this is a pure settle-and-freeze. After this,
    ///         `_updatePool` no-ops (emissions frozen) so every user's pending
    ///         phUSD is fixed at this snapshot and minted in full on their exit.
    /// @dev    Permission: `onlyMigrator`. Reverts unless the pool is `Active`,
    ///         so it runs once per engagement. The only way back to `Active` is
    ///         `finalizeAndReset`, gated on a fully-drained pool.
    function initiateMigration() external override nonReentrant onlyMigrator {
        require(poolState == PoolState.Active, "NFTStaker: not active");
        // Sweep mint debt and settle accrual to this block under the live rate,
        // then freeze. `_syncBudget` runs `_updatePool` (still Active here) so
        // pending is captured before the freeze.
        _syncBudget();
        poolState = PoolState.Migrating;
        emit MigrationInitiated(totalStaked);
    }

    /// @notice Permissioned batched migration exit. For each non-zero user:
    ///         settles and pays their frozen pending phUSD reward (respecting
    ///         solvency via `_safePay`), zeroes their position, and transfers
    ///         their staked ERC1155 amount (of `stakedId`) to the migrator.
    /// @dev    Permission: `onlyMigrator`. Requires a prior `initiateMigration`
    ///         (`Migrating`). Idempotent: an already-evacuated (zeroed) user
    ///         returns 0 and is skipped — `batchMigrate` can be safely re-run.
    ///         Callable while paused so a migration can proceed during an
    ///         incident.
    /// @param  accounts The users to migrate out (batched off-chain).
    /// @return amounts Per-user staked ERC1155 amount transferred to the
    ///         migrator, parallel to `accounts` (0 for empty / already-migrated).
    function batchMigrate(address[] calldata accounts)
        external
        override
        nonReentrant
        onlyMigrator
        returns (uint256[] memory amounts)
    {
        require(poolState == PoolState.Migrating, "NFTStaker: not migrating");

        amounts = new uint256[](accounts.length);
        uint256 totalAmount;
        for (uint256 i = 0; i < accounts.length; i++) {
            (uint256 amount, uint256 paid) = _exitPosition(accounts[i]);
            amounts[i] = amount;
            totalAmount += amount;
            if (amount > 0) emit MigratedOut(accounts[i], amount, paid);
        }
        if (totalAmount > 0) {
            stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, totalAmount, "");
        }
    }

    /// @notice Permissionless self-exit during migration: the caller redeems
    ///         their OWN position — staked ERC1155 returned to their wallet plus
    ///         pending phUSD settled — without waiting for the operator.
    /// @dev    The escape hatch for the frozen state (the `emergencyWithdraw`
    ///         and `unstake` paths remain available too, but this one settles
    ///         pending and is migration-scoped). Requires `Migrating` and a
    ///         non-zero position. Strict CEI under `nonReentrant`: the position
    ///         is zeroed inside `_exitPosition` before the ERC1155 transfer.
    function userMigrate() external nonReentrant {
        require(poolState == PoolState.Migrating, "NFTStaker: not migrating");
        require(users[msg.sender].amount > 0, "NFTStaker: nothing staked");
        (uint256 amount, uint256 paid) = _exitPosition(msg.sender);
        stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, amount, "");
        emit UserMigrated(msg.sender, amount, paid);
    }

    /// @dev Shared migration exit for one user: settles+pays their pending
    ///      phUSD (floored in the protocol's favour by the accrual machinery),
    ///      zeroes their position and decrements `totalStaked`. Returns the
    ///      staked ERC1155 `amount` (0 for an empty position) and the `paid`
    ///      phUSD reward. Does NOT transfer the ERC1155 nor emit the exit
    ///      event — the caller forwards the stake (CEI) and emits its own
    ///      `MigratedOut` / `UserMigrated`.
    function _exitPosition(address account) internal returns (uint256 amount, uint256 paid) {
        UserInfo storage user = users[account];
        amount = user.amount;
        if (amount == 0) {
            return (0, 0);
        }
        // Pending was frozen at the `initiateMigration` snapshot
        // (`_updatePool` is a no-op while Migrating).
        uint256 pending = (amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;
        if (pending > 0) {
            paid = _safePayTo(account, pending);
            if (paid > 0) emit Claimed(account, paid);
        }
    }

    /// @notice Permissioned deposit crediting `user` with `amount` ERC1155
    ///         units pulled from the migrator. Only valid while `Active`, so it
    ///         credits the new/healthy staker — never the frozen one (a deposit
    ///         on a Migrating pool would corrupt the snapshot). Callable while
    ///         paused so a freshly deployed (and possibly paused) target can be
    ///         seeded.
    /// @dev    Permission: `onlyMigrator`. Settles accrual and the user's
    ///         pending before crediting, mirroring `stake`.
    /// @param  user   The user to credit.
    /// @param  amount The ERC1155 stake amount to deposit on the user's behalf.
    function depositFor(address user, uint256 amount) external override nonReentrant onlyMigrator {
        require(amount > 0, "NFTStaker: zero deposit");
        require(poolState == PoolState.Active, "NFTStaker: not active");
        _syncBudget();
        UserInfo storage info = users[user];
        if (info.amount > 0) {
            uint256 pending = (info.amount * accRewardPerShare) / ACC_PRECISION - info.rewardDebt;
            if (pending > 0) {
                pending = _safePay(pending);
                if (pending > 0) emit Claimed(user, pending);
            }
        }
        stakedToken.safeTransferFrom(msg.sender, address(this), stakedId, amount, "");
        info.amount += amount;
        totalStaked += amount;
        info.rewardDebt = (info.amount * accRewardPerShare) / ACC_PRECISION;
        emit DepositedFor(user, amount);
        // Tail recompute: rate is `budget / windowSeconds`, totalStaked-
        // independent, but pin `windowEnd` for parity with `stake`.
        _recomputeSchedule();
    }

    /// @notice Return a fully-drained `Migrating` pool to `Active` so the SAME
    ///         staker can be revived (e.g. after an in-place dispatcher/hook
    ///         rewire). Requires every position to have exited
    ///         (`totalStaked == 0`). Fast-forwards `lastRewardTime` so the
    ///         frozen migration gap is never retro-accrued. No (R, P) snapshot
    ///         to clear (the Uniboost staker has none).
    /// @dev    Permission: `onlyOwner`. No `whenNotPaused` so the operator can
    ///         reset while paused.
    function finalizeAndReset() external onlyOwner {
        require(poolState == PoolState.Migrating, "NFTStaker: not migrating");
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        lastRewardTime = block.timestamp;
        poolState = PoolState.Active;
        emit PoolReset();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice `INFTStakerMigratable` accessor for the public `users` mapping.
    ///         Returns `user`'s currently-credited ERC1155 position and
    ///         reward-debt bookkeeping value. Used by the in-place migrator to
    ///         snapshot credited principal around a `depositFor`.
    function userInfo(address user) external view override returns (uint256 amount, uint256 rewardDebt) {
        UserInfo memory info = users[user];
        return (info.amount, info.rewardDebt);
    }

    function pendingReward(address account) external view returns (uint256) {
        UserInfo memory user = users[account];
        uint256 acc = accRewardPerShare;
        // While Migrating, emissions are frozen at the `initiateMigration`
        // snapshot — return the fixed pending with no forward projection,
        // matching what the migration exit settles.
        if (poolState == PoolState.Active && block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 end = block.timestamp < windowEnd ? block.timestamp : windowEnd;
            uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
            uint256 reward = elapsed * rewardRate;
            if (reward > rewardBudget) reward = rewardBudget;
            acc += (reward * ACC_PRECISION) / totalStaked;
        }
        return (user.amount * acc) / ACC_PRECISION - user.rewardDebt;
    }

    /// @notice Current per-second emission rate. Returns 0 once `windowEnd`
    ///         has passed (window depleted).
    function currentRewardRate() external view returns (uint256) {
        if (block.timestamp >= windowEnd) return 0;
        return rewardRate;
    }

    /// @notice Tokens currently owed to stakers: cumulative accrued-and-
    ///         unpaid rewards (`committedDebt`) plus in-flight accrual since
    ///         the last `_updatePool` boundary.
    function totalDebt() external view returns (uint256) {
        // Frozen while Migrating: no forward projection past the snapshot.
        if (poolState == PoolState.Migrating || block.timestamp <= lastRewardTime || totalStaked == 0) {
            return committedDebt;
        }
        uint256 end = block.timestamp < windowEnd ? block.timestamp : windowEnd;
        uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
        uint256 reward = elapsed * rewardRate;
        if (reward > rewardBudget) reward = rewardBudget;
        return committedDebt + reward;
    }

    /// @notice All phUSD the pool controls: held balance plus pending mint
    ///         debt still claimable from the dispatcher hook via `pull()`.
    function totalBudget() external view returns (uint256) {
        uint256 pending = address(dispatcherHook) == address(0) ? 0 : dispatcherHook.mintDebt();
        return rewardToken.balanceOf(address(this)) + pending;
    }

    /// @notice Derived runway in seconds: seconds of emissions remaining at
    ///         the current `rewardRate` against the current value V
    ///         (balance + pending mint debt). Returns 0 when the rate is
    ///         zero. Note: under the depletion model this tracks `windowEnd -
    ///         now` closely but is recomputed from live V.
    function runwaySeconds() external view returns (uint256) {
        if (rewardRate == 0) return 0;
        uint256 pending = address(dispatcherHook) == address(0) ? 0 : dispatcherHook.mintDebt();
        return (rewardToken.balanceOf(address(this)) + pending) / rewardRate;
    }
}
