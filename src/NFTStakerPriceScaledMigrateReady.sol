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
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {INFTSupply} from "./INFTSupply.sol";
import {INFTStakerMigratable} from "./INFTStakerMigratable.sol";

/// @title  NFTStakerPriceScaledMigrateReady
/// @notice Migration-capable standalone copy of `NFTStakerPriceScaled`. This
///         contract is `src/NFTStakerPriceScaled.sol` verbatim PLUS the
///         owner-driven migration block introduced for `NFTStakerDepletion` in
///         story 019 (`setMigrator` / `initiateMigration` / `batchMigrate` /
///         `userMigrate` / `depositFor` / `finalizeAndReset` / `userInfo`, the
///         `INFTStakerMigratable` interface, and `rescueERC20`).
///
///         WHY A COPY: the nft-staking repo deliberately avoids a shared base
///         contract (see `NFTStakerPriceScaled` / `NFTStakerDepletion`). The
///         live `NFTStakerPriceScaled` (the RatchetNFTStaker deployed at
///         `0x299b0071def42d35eaf5ea24cc0a71cf10655a64`) and the live audited
///         `NFTStaker` both stay byte-for-byte untouched; this variant is
///         deployed ALONGSIDE them when a price-scaled staker needs to be
///         migratable.
///
///         MAINTENANCE COUPLING: this is a HAND-MAINTAINED copy of
///         `NFTStakerPriceScaled` (which is itself a hand-maintained copy of
///         `NFTStaker`). Any future fix or audit change to either is NOT
///         automatically inherited here and MUST be mirrored manually. The
///         intended deltas vs `NFTStakerPriceScaled` are:
///           1. The contract name and `is INFTStakerMigratable`.
///           2. The story-019 migration block: `PoolState` / `poolState` /
///              `migrator` state, the `onlyMigrator` modifier, the six
///              migration events, and the migration primitives.
///           3. `_safePayTo(address,uint256)` added; `_safePay(uint256)`
///              delegates to it so `batchMigrate` can pay the USER rather than
///              the migrator (`msg.sender`).
///           4. Freeze hooks: `_updatePool` early-returns while `Migrating`
///              (fast-forwarding `lastRewardTime` so the frozen gap is never
///              retro-accrued), `pendingReward` only projects forward while
///              `Active`, and `totalDebt` returns `committedDebt` while
///              `Migrating`.
///           5. `rescueERC20` (+ `Rescued` event, `Rescue__ZeroRecipient`
///              error) ported from `NFTStakerDepletion`.
///           6. PRICE-SCALED-SPECIFIC: unlike the depletion model, the reward
///              rate here DEPENDS on `totalStaked` (`S = totalStaked *
///              latestPrice`), and migration mutates `totalStaked`. Hence:
///                a. the accrual-path recomputes (`_syncBudget`, and the
///                   `stake` / `unstake` tails) route through
///                   `_recomputeScheduleIfActive()` so the frozen snapshot's
///                   `rewardRate` / `windowEnd` / `rewardBudget` cannot move
///                   while `Migrating`;
///                b. `depositFor` carries a TAIL `_recomputeSchedule()`
///                   mirroring `stake` — load-bearing here, not cosmetic;
///                c. `finalizeAndReset` re-derives the schedule against the
///                   post-migration (empty) pool, exactly as an
///                   `unstake`-to-zero does.
///
/// @notice Masterchef-style staking pool for a single ERC1155 token ID.
///         Stakers deposit ERC1155 units of `stakedId` and earn per-second
///         emissions of `rewardToken` (phUSD). The emission schedule is
///         derived from an owner-set `targetAPY` and the staked-subset
///         notional `S = totalStaked * latestPrice` (where `latestPrice`
///         is the most-recent paid mint price); the runway (time until
///         depletion) is a derived quantity `V / R` rather than a fixed
///         knob. Sizing the rate against the staked subset (rather than
///         the aggregate notional of every minted NFT) closes audit
///         finding M-03: a lone staker among many minters earns at most
///         `targetAPY` for their NFT, never `N * targetAPY`.
contract NFTStakerPriceScaledMigrateReady is
    Ownable,
    Pausable,
    ReentrancyGuard,
    ERC1155Holder,
    IPausable,
    INFTStakerMigratable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant ACC_PRECISION = 1e18;

    /// @notice Seconds in a financial year (365 days). APY is a financial
    ///         convention; mainstream DeFi rate calcs (Compound, Aave) use
    ///         a 365-day or block-count year rather than the astronomical
    ///         365.25. The 21.6-minute drift per year vs real time is well
    ///         below other approximations in the model.
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice 1e18 scaling factor for `targetAPY` and the geometric-series
    ///         fixed-point math.
    uint256 public constant APY_PRECISION = 1e18;

    /// @notice Hard ceiling for `targetAPY`. Derived from the phUSD mint
    ///         ceiling per NFT — every NFT mints 50% of its value as phUSD,
    ///         so APYs strictly greater than 50% cannot be sustained by
    ///         mint debt alone. Values exactly at the cap are accepted.
    uint256 public constant MAX_TARGET_APY = 50 * 1e16; // 0.5e18 = 50%

    // ---------------------------------------------------------------------
    // Config (immutable)
    // ---------------------------------------------------------------------

    IERC1155 public immutable stakedToken;
    IERC20 public immutable rewardToken;

    /// @notice Multiplier that normalizes the dispatcher's mint `price` (denominated in the
    ///         dispatcher's prime token) into reward-token (phUSD) units before it is used as the
    ///         NFT-value proxy in the emission-rate calc. Equals 10 ** (rewardDecimals - priceDecimals).
    ///         - prime token == reward decimals (USDS 18dp -> phUSD 18dp): 1 (== original NFTStaker).
    ///         - 6dp prime token (USDC) -> 18dp phUSD: 1e12.
    ///         Immutable: a new scale means a new staker (a live change would swing APY mid-stake).
    uint256 public immutable priceScale;

    // ---------------------------------------------------------------------
    // Config (mutable, owner-controlled)
    // ---------------------------------------------------------------------

    /// @notice The ERC1155 token ID currently being staked. Mutable but only
    ///         changeable while `totalStaked == 0`.
    uint256 public stakedId;

    /// @notice Dispatcher hook supplying phUSD via `pull()`. Set post-deploy.
    IBalancerPoolerMintDebtHook public dispatcherHook;

    /// @notice Address authorised to pause/unpause via the global pauser.
    address public pauser;

    /// @notice Re-typed reference to NFTMinterV2 for supply and configs
    ///         reads. In production this is the same contract as
    ///         `stakedToken`; the split lets us type the variable without
    ///         casting in hot paths.
    INFTSupply public nftMinter;

    /// @notice Index into `nftMinter.configs` identifying the dispatcher
    ///         whose price / growthBasisPoints govern the NFT-value
    ///         calculation. Owner-settable only when `totalStaked == 0`.
    uint256 public dispatcherIndex;

    /// @notice 1e18-scaled target annual percentage yield for the latest
    ///         minter (the staker who paid `latestPrice`). Earlier minters
    ///         paid less than `latestPrice` and earn proportionally more —
    ///         see the "APY-as-floor for latest minter" invariant in
    ///         CLAUDE.md. `0.3e18` = 30%. Bounded by `MAX_TARGET_APY`.
    uint256 public targetAPY;

    // ---------------------------------------------------------------------
    // Schedule state
    // ---------------------------------------------------------------------

    /// @notice Timestamp at which the current schedule depletes the
    ///         available value at `rewardRate`. Derived, not owner-set.
    uint256 public windowEnd;

    /// @notice Per-second phUSD emissions. Recomputed from
    ///         `S * targetAPY / SECONDS_PER_YEAR` on every interaction,
    ///         where `S = totalStaked * latestPrice` is the staked-subset
    ///         notional valued at the most-recent paid mint price.
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
    ///      non-zero inflow. Signature simplified from the story-005 model:
    ///      the schedule is recomputed from the APY target independently of
    ///      inflow size, so rate/windowEnd no longer belong on this event
    ///      (see `ScheduleRecomputed`).
    event Pulled(uint256 inflow, uint256 newBudget);
    /// @dev Emitted on a successful owner top-up. Signature simplified for
    ///      the same reason as `Pulled`.
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event TargetAPYChanged(uint256 previous, uint256 next);
    event DispatcherIndexChanged(uint256 previous, uint256 next);
    event NFTMinterChanged(address indexed previous, address indexed next);
    /// @dev Emitted whenever `_recomputeSchedule` runs. Fields are the
    ///      staked-subset notional `S = totalStaked * latestPrice` (the
    ///      basis the rate is sized against, post-audit M-03), the
    ///      `availableValue` available for emissions (`V - committedDebt`,
    ///      i.e. the budget left after accounting for already-committed
    ///      accrual per audit M-01), the new per-second rate, and the
    ///      derived windowEnd timestamp.
    ///      NOTE: the first field name (`totalNFTValue`) is preserved
    ///      from the pre-M-03 schema to minimise off-chain consumer
    ///      churn, but the value's MEANING shifted: pre-M-03 it carried
    ///      the aggregate notional `T` of all minted NFTs; post-M-03 it
    ///      carries the staked-subset notional `S`.
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
        uint256 _dispatcherIndex,
        uint256 _priceScale
    ) Ownable(_initialOwner) {
        require(address(_stakedToken) != address(0), "NFTStaker: zero staked token");
        require(address(_rewardToken) != address(0), "NFTStaker: zero reward token");
        require(address(_nftMinter) != address(0), "NFTStaker: zero nft minter");
        require(_priceScale != 0, "NFTStaker: zero price scale");
        stakedToken = _stakedToken;
        stakedId = _stakedId;
        rewardToken = _rewardToken;
        nftMinter = _nftMinter;
        dispatcherIndex = _dispatcherIndex;
        priceScale = _priceScale;
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

    function setDispatcherHook(IBalancerPoolerMintDebtHook newHook) external onlyOwner {
        emit DispatcherHookChanged(address(dispatcherHook), address(newHook));
        dispatcherHook = newHook;
    }

    function setStakedId(uint256 newId) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit StakedIdChanged(stakedId, newId);
        stakedId = newId;
    }

    /// @notice Update the dispatcher index read from `nftMinter.configs`.
    ///         Guarded by `totalStaked == 0` — a mid-stake swap to a
    ///         different dispatcher could swing APY violently in either
    ///         direction, so the safest policy is to require an empty pool.
    function setDispatcherIndex(uint256 newIndex) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit DispatcherIndexChanged(dispatcherIndex, newIndex);
        dispatcherIndex = newIndex;
        _recomputeSchedule();
    }

    /// @notice Swap the `nftMinter` reference. Guarded by
    ///         `totalStaked == 0` for the same reason as `setStakedId` and
    ///         `setDispatcherIndex`.
    function setNFTMinter(INFTSupply newMinter) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        require(address(newMinter) != address(0), "NFTStaker: zero nft minter");
        emit NFTMinterChanged(address(nftMinter), address(newMinter));
        nftMinter = newMinter;
        _recomputeSchedule();
    }

    /// @notice Update the target APY. Settles in-flight accrual at the OLD
    ///         rate before mutating so existing stakers are paid what they
    ///         earned under the prior policy. Allows `targetAPY == 0`
    ///         (pauses emissions via policy rather than via `pause()`).
    /// @param  newAPY 1e18-scaled fraction, `<= MAX_TARGET_APY`.
    function setTargetAPY(uint256 newAPY) external onlyOwner {
        require(newAPY <= MAX_TARGET_APY, "NFTStaker: APY too high");
        _updatePool();
        emit TargetAPYChanged(targetAPY, newAPY);
        targetAPY = newAPY;
        _recomputeSchedule();
    }

    /// @notice Owner-only refill of the reward budget. Transfers `amount`
    ///         phUSD into the contract then recomputes the schedule from
    ///         the current APY target and the new V. Does not call
    ///         `_syncBudget`, preserving the dispatcher-hook-independence
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
    ///
    ///      PRICE-SCALED DELTA vs `NFTStakerDepletion`: the recompute here is
    ///      UNCONDITIONAL (it does not wait for a non-zero inflow), because
    ///      the rate depends on `totalStaked` rather than on the budget alone.
    ///      It is therefore routed through `_recomputeScheduleIfActive` so it
    ///      cannot move the frozen snapshot while `Migrating`.
    function _syncBudget() internal {
        _updatePool();
        if (address(dispatcherHook) == address(0)) {
            _recomputeScheduleIfActive();
            return;
        }
        uint256 pre = rewardToken.balanceOf(address(this));
        dispatcherHook.pull();
        uint256 inflow = rewardToken.balanceOf(address(this)) - pre;
        _recomputeScheduleIfActive();
        if (inflow > 0) {
            emit Pulled(inflow, rewardBudget);
        }
    }

    /// @dev Accrual-path recompute guard. While `Migrating`, `rewardRate` /
    ///      `windowEnd` / `rewardBudget` are pinned to the
    ///      `initiateMigration` snapshot, so the recomputes that hang off the
    ///      user-interaction path (`_syncBudget` and the `stake` / `unstake`
    ///      tails) must no-op. Owner-driven recomputes (`setTargetAPY`,
    ///      `topUp`, `rescueERC20`, `finalizeAndReset`, the empty-pool
    ///      setters) call `_recomputeSchedule` directly and are deliberate.
    function _recomputeScheduleIfActive() internal {
        if (poolState == PoolState.Migrating) return;
        _recomputeSchedule();
    }

    /// @dev Settles per-share accrual from `lastRewardTime` up to
    ///      `min(now, windowEnd)` under the current `rewardRate`. Moves the
    ///      accrued amount out of `rewardBudget` and into `committedDebt`
    ///      (preserving `balance == rewardBudget + committedDebt`), then
    ///      bakes it into `accRewardPerShare`. Clamps the move to the
    ///      remaining `rewardBudget` to guarantee clean depletion.
    function _updatePool() internal {
        // While Migrating, emissions are frozen: every user's pending phUSD is
        // fixed at the `initiateMigration` snapshot and paid in full on their
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

    /// @dev Closed-form recompute of the emission schedule. Reads live
    ///      state from the NFT minter and dispatcher hook; sets
    ///      `rewardRate`, `rewardBudget`, `windowEnd` per the APY target.
    ///
    ///      Math (all values in 1e18 fp unless noted):
    ///        r           = 1 + growthBasisPoints / 10_000
    ///        latestPrice = price / r
    ///        S           = totalStaked * latestPrice           // staked subset
    ///        V           = balance + mintDebt
    ///        budget      = V - committedDebt                   // M-01
    ///        F           = S * targetAPY
    ///        R           = F / SECONDS_PER_YEAR
    ///        runway      = budget / R                          (seconds)
    ///
    ///      Audit M-03: the rate is sized against the staked subset
    ///      `S = totalStaked * latestPrice` rather than the aggregate
    ///      notional of every minted NFT. This eliminates the
    ///      `effectiveAPY = targetAPY * (N / totalStaked)` participation
    ///      multiplier the audit flagged: per-NFT emissions = latestPrice
    ///      * targetAPY / SECONDS_PER_YEAR, the latest minter (paid
    ///      `latestPrice`) earns exactly `targetAPY`, and earlier minters
    ///      earn `targetAPY * (latestPrice / theirMintPrice) > targetAPY`.
    ///
    ///      `latestPrice` recovery: `nftMinter.configs(dispatcherIndex)`
    ///      returns the NEXT mint price (`price`); after each mint the
    ///      contract scales it up by `r`, so the most-recent paid price
    ///      is `price / r`. With `growthBasisPoints == 0` this collapses
    ///      to `latestPrice = price`.
    ///
    ///      Edge cases:
    ///        totalStaked == 0 || price == 0 || targetAPY == 0
    ///                                      -> rate 0, windowEnd = now.
    ///        growthBasisPoints == 0        -> latestPrice = price (no
    ///                                         geometric scaling).
    ///
    ///      `totalStaked * latestPrice` overflow: `totalStaked` is bounded
    ///      by realistic ERC1155 supply (≤ 1e6 in practice); `latestPrice`
    ///      is wei-scaled mint price (~1e21 for typical configs). Product
    ///      ≤ ~1e27 * priceScale (≤ 2^256 for priceScale ≤ 1e12),
    ///      comfortably below 2^256.
    ///
    ///      Rounding: the single `latestPrice = price.mulDiv(1e18, r)`
    ///      floor is the only non-bare-multiply path; `F`, `newRate`, and
    ///      `runway` floor again downstream, each shaving at most 1 wei in
    ///      the protocol's favour. Net bias on `R` is a handful of wei
    ///      below exact in expectation. DO NOT flip any site to ceiling
    ///      rounding — doing so on the rate or runway path would let users
    ///      draw against rewards the contract has not budgeted for.
    function _recomputeSchedule() internal {
        (, uint256 price, uint256 growthBasisPoints,) = nftMinter.configs(dispatcherIndex);

        uint256 latestPrice;
        if (price == 0) {
            latestPrice = 0;
        } else if (growthBasisPoints == 0) {
            latestPrice = price;
        } else {
            uint256 r = APY_PRECISION + growthBasisPoints * 1e14;
            latestPrice = price.mulDiv(APY_PRECISION, r);
        }

        // Normalize the dispatcher price (prime-token decimals) into reward-token (phUSD) units.
        // priceScale == 1 reproduces the original NFTStaker exactly; 1e12 for a 6dp USDC-priced dispatcher.
        latestPrice = latestPrice * priceScale;

        // M-03: size the rate against the staked subset, not the aggregate
        // notional of all minted NFTs. Bare multiplication is exact and
        // cheaper than a mulDiv; the bound argument lives in the NatSpec.
        uint256 S = (totalStaked == 0 || latestPrice == 0) ? 0 : totalStaked * latestPrice;

        uint256 V = rewardToken.balanceOf(address(this));
        if (address(dispatcherHook) != address(0)) {
            V += dispatcherHook.mintDebt();
        }

        // Strip already-committed accrual from V before sizing the next
        // budget. This is the M-01 fix: re-using V here over-promised by
        // the amount `_updatePool` had just moved into `accRewardPerShare`,
        // DoSing late claimers via `_safePay` shortfalls. Clamp at zero to
        // keep recompute non-reverting if hook misbehaviour ever drives V
        // below committedDebt (principal escape via emergencyWithdraw).
        uint256 budget = V > committedDebt ? V - committedDebt : 0;

        uint256 F = S.mulDiv(targetAPY, APY_PRECISION);
        uint256 newRate = (F == 0) ? 0 : F / SECONDS_PER_YEAR;
        uint256 runway = (newRate == 0) ? 0 : budget / newRate;

        rewardRate = newRate;
        rewardBudget = budget;
        windowEnd = block.timestamp + runway;

        emit ScheduleRecomputed(S, budget, newRate, windowEnd);
    }

    // ---------------------------------------------------------------------
    // User entrypoints
    // ---------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "NFTStaker: zero stake");
        // Head: settle accrual at the OLD rate against the OLD totalStaked
        // (preserves "late stakers never get retroactive rewards"). Sweeps
        // mint debt and recomputes too; we re-recompute at the tail.
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
        // Tail (audit M-03): R scales linearly with `totalStaked`, so re-
        // size R against the post-mutation pool. No `_syncBudget` here:
        // no time has elapsed since the head and `mintDebt` cannot change
        // mid-call, so a bare `_recomputeSchedule` suffices and avoids
        // a second `pull()` round-trip. Suppressed while `Migrating` so the
        // frozen snapshot is never disturbed.
        _recomputeScheduleIfActive();
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
        // Tail (audit M-03): see `stake` rationale. Without this, an
        // unstake leaves R sized for the OLD larger pool and the
        // remaining stakers over-collect until the next interaction.
        _recomputeScheduleIfActive();
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
    ///      on-chain balance is insufficient (no silent forfeiture). See
    ///      `_safePayTo` for the full solvency argument.
    function _safePay(uint256 amount) internal returns (uint256) {
        return _safePayTo(msg.sender, amount);
    }

    /// @dev `_safePay` variant that pays an explicit `account` rather than
    ///      `msg.sender`. Needed by the migration paths, where `batchMigrate`'s
    ///      `msg.sender` is the migrator but the settled phUSD reward must be
    ///      paid to the migrating user.
    ///
    ///      After the transfer succeeds, decrement
    ///      `(committedDebt + rewardBudget)` by `amount` to preserve the strong
    ///      invariant `balance == rewardBudget + committedDebt` — balance drops
    ///      by `amount`, so the sum on the right must drop by the same.
    ///
    ///      In the common path, all of `amount` comes out of `committedDebt`
    ///      because `accRewardPerShare`-derived `pending` is fully baked in
    ///      by the upstream `_updatePool`. In the floor-division dust case,
    ///      per-user `pending` (computed via two separate floor operations
    ///      on `user.amount * acc / ACC_PRECISION`) can marginally exceed
    ///      the cumulative reward `_updatePool` moved into `committedDebt`
    ///      — at most ~1 wei per claim per user. The `if (amount >
    ///      committedDebt)` branch absorbs that excess from `rewardBudget`,
    ///      which is safe because the `balance >= amount` precondition
    ///      together with the invariant guarantees `rewardBudget +
    ///      committedDebt >= amount`. The shortfall revert path on a
    ///      genuine balance gap is unchanged.
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
    ///
    ///         Forfeited rewards: the user's pending against the CURRENT
    ///         `accRewardPerShare` (i.e. their share of already-committed
    ///         debt) is decremented from `committedDebt`. In-flight accrual
    ///         since the last `_updatePool` is not yet reflected in
    ///         `accRewardPerShare`, so it is not subtracted here — it stays
    ///         in `rewardBudget` and is recycled into the next recompute,
    ///         which is the correct behaviour. This preserves the strong
    ///         invariant `balance == rewardBudget + committedDebt` after
    ///         the call.
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = users[msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "NFTStaker: nothing to withdraw");
        uint256 pending = (amount * accRewardPerShare) / ACC_PRECISION - user.rewardDebt;
        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;
        if (pending > 0) {
            // Bound by the current `committedDebt` to absorb any
            // floor-division dust where the user's accumulated pending
            // marginally exceeds the cumulative committed total. Forfeited
            // phUSD stays in the contract balance, so to preserve the
            // strong invariant `balance == rewardBudget + committedDebt`
            // it must be reabsorbed into the rewardBudget pool — it then
            // recycles into the next recompute as fresh runway for
            // surviving stakers.
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
    ///         freeze emissions by flipping `poolState` to `Migrating`. There is
    ///         NO yield-strategy unwind — the staker's budget is idle
    ///         rewardToken + hook mint-debt, so this is a pure settle-and-freeze.
    ///         After this, `_updatePool` no-ops (emissions frozen) so every
    ///         user's pending phUSD is fixed at this snapshot and paid in full on
    ///         their exit.
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
    ///         solvency via `_safePayTo`), zeroes their position, and transfers
    ///         their staked ERC1155 amount (of `stakedId`) to the migrator.
    /// @dev    Permission: `onlyMigrator`. Requires a prior `initiateMigration`
    ///         (`Migrating`). Idempotent: an already-evacuated (zeroed) user
    ///         returns 0 and is skipped — `batchMigrate` can be safely re-run.
    ///         Callable while paused so a migration can proceed during an
    ///         incident. No tail recompute: the schedule stays pinned to the
    ///         frozen snapshot until `finalizeAndReset` re-derives it.
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
    ///
    ///         DELTA vs `NFTStakerDepletion.depositFor`: the pre-credit
    ///         settlement pays via `_safePayTo(user, ...)` rather than
    ///         `_safePay(...)`. `msg.sender` here is the MIGRATOR, so the
    ///         `_safePay` form would route an existing staker's earned phUSD to
    ///         the orchestrator while emitting `Claimed(user, ...)`. Only
    ///         reachable when the deposit target already holds a position (a
    ///         partial `InPlaceNFTStakerMigrator` round-trip, or migrating into
    ///         a staker the user is already in), but wrong in every case.
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
                pending = _safePayTo(user, pending);
                if (pending > 0) emit Claimed(user, pending);
            }
        }
        stakedToken.safeTransferFrom(msg.sender, address(this), stakedId, amount, "");
        info.amount += amount;
        totalStaked += amount;
        info.rewardDebt = (info.amount * accRewardPerShare) / ACC_PRECISION;
        emit DepositedFor(user, amount);
        // Tail recompute (PRICE-SCALED DELTA): unlike the depletion model this
        // is LOAD-BEARING, not cosmetic — `R = S * targetAPY / SECONDS_PER_YEAR`
        // with `S = totalStaked * latestPrice`, so a `depositFor` that grows
        // `totalStaked` must re-size R against the post-mutation pool exactly
        // as `stake` does. Unguarded: `depositFor` requires `Active`.
        _recomputeSchedule();
    }

    /// @notice Return a fully-drained `Migrating` pool to `Active` so the SAME
    ///         staker can be revived (e.g. after an in-place dispatcher/hook
    ///         rewire). Requires every position to have exited
    ///         (`totalStaked == 0`). Fast-forwards `lastRewardTime` so the
    ///         frozen migration gap is never retro-accrued. No (R, P) snapshot
    ///         to clear (this staker has none).
    /// @dev    Permission: `onlyOwner`. No `whenNotPaused` so the operator can
    ///         reset while paused.
    ///
    ///         PRICE-SCALED DELTA: the pre-migration `rewardRate` was sized
    ///         against the pre-migration `totalStaked`; leaving it in place
    ///         after the drain would let the first post-reset `_updatePool`
    ///         accrue at a rate the (now empty, or refilled-differently) pool
    ///         never justified. The state flips to `Active` FIRST and then
    ///         `_recomputeSchedule()` re-derives against the live pool. At
    ///         `totalStaked == 0` this yields `S == 0` -> `rewardRate == 0`,
    ///         `windowEnd == block.timestamp`, and `rewardBudget` re-sized to
    ///         `V - committedDebt` — byte-identical to what an `unstake` down
    ///         to zero leaves behind, which is the behaviour this deliberately
    ///         mirrors. A subsequent `stake` / `depositFor` re-sizes R via its
    ///         own tail recompute.
    function finalizeAndReset() external onlyOwner {
        require(poolState == PoolState.Migrating, "NFTStaker: not migrating");
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        lastRewardTime = block.timestamp;
        poolState = PoolState.Active;
        _recomputeSchedule();
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

    /// @notice Current per-second emission rate. Returns 0 once the derived
    ///         `windowEnd` has passed (runway depleted).
    function currentRewardRate() external view returns (uint256) {
        if (block.timestamp >= windowEnd) return 0;
        return rewardRate;
    }

    /// @notice Tokens currently owed to stakers: cumulative accrued-and-
    ///         unpaid rewards (`committedDebt`) plus in-flight accrual since
    ///         the last `_updatePool` boundary. Reads `committedDebt`
    ///         directly — the strong invariant
    ///         `balance == rewardBudget + committedDebt` makes this an O(1)
    ///         passthrough plus a forward simulation of the next
    ///         `_updatePool` call.
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
    ///         zero.
    function runwaySeconds() external view returns (uint256) {
        if (rewardRate == 0) return 0;
        uint256 pending = address(dispatcherHook) == address(0) ? 0 : dispatcherHook.mintDebt();
        return (rewardToken.balanceOf(address(this)) + pending) / rewardRate;
    }
}
