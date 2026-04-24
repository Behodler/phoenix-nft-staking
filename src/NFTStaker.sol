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
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";
import {INFTSupply} from "./INFTSupply.sol";

/// @title  NFTStaker
/// @notice Masterchef-style staking pool for a single ERC1155 token ID.
///         Stakers deposit ERC1155 units of `stakedId` and earn per-second
///         emissions of `rewardToken` (phUSD). The emission schedule is
///         derived from an owner-set `targetAPY` and the live aggregate
///         NFT value read from `nftMinter`; the runway (time until
///         depletion) is a derived quantity `V / F` rather than a fixed
///         knob. See the parent CLAUDE.md and
///         `scratchpad/planning-docs/phoenix/phase2/nft-staking/variable-runway.md`
///         for the full design.
contract NFTStaker is Ownable, Pausable, ReentrancyGuard, ERC1155Holder, IPausable {
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

    /// @notice 1e18-scaled target annual percentage yield for the average
    ///         NFT. `0.3e18` = 30% APY. Bounded by `MAX_TARGET_APY`.
    uint256 public targetAPY;

    // ---------------------------------------------------------------------
    // Schedule state
    // ---------------------------------------------------------------------

    /// @notice Timestamp at which the current schedule depletes the
    ///         available value at `rewardRate`. Derived, not owner-set.
    uint256 public windowEnd;

    /// @notice Per-second phUSD emissions. Recomputed from
    ///         `T * targetAPY / SECONDS_PER_YEAR` on every interaction.
    uint256 public rewardRate;

    /// @notice Value budgeted for the current schedule, equal to
    ///         `V = balance + mintDebt` at the most recent recompute (after
    ///         any pull). Decreases as `_updatePool` settles accrual.
    uint256 public rewardBudget;

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
    ///      closed-form T (aggregate NFT value), V (available value incl.
    ///      pending mint debt), the new per-second rate, and the derived
    ///      windowEnd timestamp.
    event ScheduleRecomputed(uint256 totalNFTValue, uint256 availableValue, uint256 newRate, uint256 newWindowEnd);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyPauser() {
        require(msg.sender == pauser, "NFTStaker: caller is not pauser");
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

    // ---------------------------------------------------------------------
    // Internal funding mechanics
    // ---------------------------------------------------------------------

    /// @dev Materialises pending mint debt as phUSD via `pull()`, then
    ///      recomputes the emission schedule against the new balance. If
    ///      the hook is unset, behaves like a pure recompute (still useful
    ///      after a state-changing config setter).
    function _syncBudget() internal {
        _updatePool();
        if (address(dispatcherHook) == address(0)) {
            _recomputeSchedule();
            return;
        }
        uint256 pre = rewardToken.balanceOf(address(this));
        dispatcherHook.pull();
        uint256 inflow = rewardToken.balanceOf(address(this)) - pre;
        _recomputeSchedule();
        if (inflow > 0) {
            emit Pulled(inflow, rewardBudget);
        }
    }

    /// @dev Settles per-share accrual from `lastRewardTime` up to
    ///      `min(now, windowEnd)` under the current `rewardRate`.
    ///      Decrements `rewardBudget` by the amount accrued and clamps to
    ///      `rewardBudget` to guarantee clean depletion.
    function _updatePool() internal {
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
            accRewardPerShare += (reward * ACC_PRECISION) / totalStaked;
        }
        lastRewardTime = block.timestamp;
    }

    /// @dev Closed-form recompute of the emission schedule. Reads live
    ///      state from the NFT minter and dispatcher hook; sets
    ///      `rewardRate`, `rewardBudget`, `windowEnd` per the APY target.
    ///
    ///      Math (all values in 1e18 fp unless noted):
    ///        r          = 1 + growthBasisPoints / 10_000
    ///        latestPrice = price / r
    ///        T          = latestPrice * (r^N - 1) / (r^(N-1) * (r - 1))
    ///        V          = balance + mintDebt
    ///        F          = T * targetAPY
    ///        R          = F / SECONDS_PER_YEAR
    ///        runway     = V / R        (seconds)
    ///
    ///      Edge cases:
    ///        N == 0 or targetAPY == 0     -> rate 0, windowEnd = now.
    ///        N == 1                      -> T = latestPrice exactly.
    ///        growthBasisPoints == 0      -> T = latestPrice * N (no
    ///                                      geometric series, avoids the
    ///                                      `r - 1 == 0` divide-by-zero).
    ///
    ///      Every `mulDiv` floors. That bias under-states `T` slightly,
    ///      which is the conservative direction for a reward contract;
    ///      DO NOT flip to ceiling rounding.
    function _recomputeSchedule() internal {
        (, uint256 price, uint256 growthBasisPoints,) = nftMinter.configs(dispatcherIndex);
        uint256 N = nftMinter.totalSupply(stakedId);

        uint256 T;
        if (N == 0 || price == 0) {
            T = 0;
        } else if (growthBasisPoints == 0) {
            // No geometric growth — uniform price.
            T = price * N;
        } else {
            uint256 r = APY_PRECISION + growthBasisPoints * 1e14;
            uint256 latestPrice = price.mulDiv(APY_PRECISION, r);
            if (N == 1) {
                T = latestPrice;
            } else {
                uint256 rPowN = FixedPointMathLib.rpow(r, N, APY_PRECISION);
                uint256 rPowNm1 = FixedPointMathLib.rpow(r, N - 1, APY_PRECISION);
                uint256 rMinusOne = r - APY_PRECISION;
                uint256 num = latestPrice.mulDiv(rPowN - APY_PRECISION, APY_PRECISION);
                uint256 den = rPowNm1.mulDiv(rMinusOne, APY_PRECISION);
                T = num.mulDiv(APY_PRECISION, den);
            }
        }

        uint256 V = rewardToken.balanceOf(address(this));
        if (address(dispatcherHook) != address(0)) {
            V += dispatcherHook.mintDebt();
        }

        uint256 F = T.mulDiv(targetAPY, APY_PRECISION);
        uint256 newRate = (F == 0) ? 0 : F / SECONDS_PER_YEAR;
        uint256 runway = (newRate == 0) ? 0 : V / newRate;

        rewardRate = newRate;
        rewardBudget = V;
        windowEnd = block.timestamp + runway;

        emit ScheduleRecomputed(T, V, newRate, windowEnd);
    }

    // ---------------------------------------------------------------------
    // User entrypoints
    // ---------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "NFTStaker: zero stake");
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
    ///      on-chain balance is insufficient. `_syncBudget` is always
    ///      called upstream of every payout path, so any remaining shortfall
    ///      at this point is a genuine liquidity gap. Reverting here
    ///      prevents silent forfeiture of earned rewards (audit M-01).
    ///      `balance == rewardBudget + totalDebt` is the post-recompute
    ///      invariant; between recomputes `_updatePool` decrements
    ///      `rewardBudget` while balance stays constant modulo `_safePay`s.
    function _safePay(uint256 amount) internal returns (uint256) {
        require(rewardToken.balanceOf(address(this)) >= amount, "NFTStaker: insufficient reward balance");
        if (amount > 0) {
            rewardToken.safeTransfer(msg.sender, amount);
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
        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;
        stakedToken.safeTransferFrom(address(this), msg.sender, stakedId, amount, "");
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function pendingReward(address account) external view returns (uint256) {
        UserInfo memory user = users[account];
        uint256 acc = accRewardPerShare;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
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

    /// @notice Tokens currently owed to stakers: accrued but unclaimed
    ///         rewards including in-flight accrual since `lastRewardTime`.
    ///         Derived from `balance == rewardBudget + totalDebt` (holds
    ///         at recompute boundaries; between recomputes `_updatePool`
    ///         decrements `rewardBudget` while balance is static).
    function totalDebt() external view returns (uint256) {
        uint256 budget = rewardBudget;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 end = block.timestamp < windowEnd ? block.timestamp : windowEnd;
            uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
            uint256 reward = elapsed * rewardRate;
            if (reward > budget) reward = budget;
            budget -= reward;
        }
        uint256 balance = rewardToken.balanceOf(address(this));
        return balance > budget ? balance - budget : 0;
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
