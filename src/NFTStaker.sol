// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    ERC1155Holder
} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {
    IBalancerPoolerMintDebtHook
} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";

/// @title  NFTStaker
/// @notice Masterchef-style staking pool for a single ERC1155 token ID.
///         Stakers deposit ERC1155 units of `stakedId` and earn per-second
///         emissions of `rewardToken` (phUSD). The reward budget is funded
///         by `pull()`-ing accrued mint debt from the configured dispatcher
///         hook plus owner top-ups. See `docs/design.md` (in the
///         product-owner repo) for the full design rationale.
contract NFTStaker is
    Ownable,
    Pausable,
    ReentrancyGuard,
    ERC1155Holder,
    IPausable
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant DEFAULT_WINDOW = 540 days;
    uint256 public constant MIN_WINDOW = 1 days;
    uint256 public constant MAX_WINDOW = 10 * 365 days;

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

    // ---------------------------------------------------------------------
    // Window state
    // ---------------------------------------------------------------------

    uint256 public windowDuration;
    uint256 public windowEnd;
    uint256 public rewardRate;
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
    event Pulled(
        uint256 inflow,
        uint256 newBudget,
        uint256 newRate,
        uint256 newWindowEnd
    );
    event ToppedUp(
        address indexed from,
        uint256 amount,
        uint256 newBudget,
        uint256 newRate
    );
    event WindowDurationChanged(uint256 previous, uint256 next);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event PauserChanged(
        address indexed previousPauser,
        address indexed newPauser
    );

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
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(
            address(_stakedToken) != address(0),
            "NFTStaker: zero staked token"
        );
        require(
            address(_rewardToken) != address(0),
            "NFTStaker: zero reward token"
        );
        stakedToken = _stakedToken;
        stakedId = _stakedId;
        rewardToken = _rewardToken;
        windowDuration = DEFAULT_WINDOW;
    }

    // ---------------------------------------------------------------------
    // Owner / pauser admin (existing wiring preserved)
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
    // Owner setters (stubbed)
    // ---------------------------------------------------------------------

    function setDispatcherHook(
        IBalancerPoolerMintDebtHook newHook
    ) external onlyOwner {
        emit DispatcherHookChanged(address(dispatcherHook), address(newHook));
        dispatcherHook = newHook;
    }

    function setStakedId(uint256 newId) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit StakedIdChanged(stakedId, newId);
        stakedId = newId;
    }

    function setWindowDuration(uint256 newDuration) external onlyOwner {
        require(
            newDuration >= MIN_WINDOW && newDuration <= MAX_WINDOW,
            "NFTStaker: window out of bounds"
        );
        // Settle accrual under the OLD rate before mutating the schedule.
        _updatePool();
        emit WindowDurationChanged(windowDuration, newDuration);
        windowDuration = newDuration;
        // Reset the active window/rate against the existing budget.
        windowEnd = block.timestamp + newDuration;
        rewardRate = newDuration == 0 ? 0 : rewardBudget / newDuration;
    }

    function topUp(uint256 amount) external onlyOwner {
        require(amount > 0, "NFTStaker: zero topUp");
        // Settle accrual at OLD rate before mutating the schedule.
        _updatePool();
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardBudget += amount;
        windowEnd = block.timestamp + windowDuration;
        rewardRate = rewardBudget / windowDuration;
        emit ToppedUp(msg.sender, amount, rewardBudget, rewardRate);
    }

    /// @notice Public wrapper for the implicit `_syncBudget()` performed at the
    ///         start of every user action. Useful for keepers and for tests.
    function pullAndRefresh() external {
        _syncBudget();
    }

    // ---------------------------------------------------------------------
    // Internal funding mechanics
    // ---------------------------------------------------------------------

    function _syncBudget() internal {
        // Always settle accrual under the OLD rate before mutating anything.
        _updatePool();
        if (address(dispatcherHook) == address(0)) return;
        uint256 pre = rewardToken.balanceOf(address(this));
        dispatcherHook.pull();
        uint256 inflow = rewardToken.balanceOf(address(this)) - pre;
        if (inflow == 0) return;
        rewardBudget += inflow;
        windowEnd = block.timestamp + windowDuration;
        rewardRate = rewardBudget / windowDuration;
        emit Pulled(inflow, rewardBudget, rewardRate, windowEnd);
    }

    /// @dev Settles per-share accrual from `lastRewardTime` up to `min(now, windowEnd)`
    ///      under the current `rewardRate`. Decrements `rewardBudget` by the
    ///      amount accrued and clamps to `rewardBudget` to guarantee clean depletion.
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

    // ---------------------------------------------------------------------
    // User entrypoints
    // ---------------------------------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "NFTStaker: zero stake");
        _syncBudget();
        UserInfo storage user = users[msg.sender];
        if (user.amount > 0) {
            uint256 pending = (user.amount * accRewardPerShare) /
                ACC_PRECISION -
                user.rewardDebt;
            if (pending > 0) {
                pending = _safePay(pending);
                if (pending > 0) emit Claimed(msg.sender, pending);
            }
        }
        stakedToken.safeTransferFrom(
            msg.sender,
            address(this),
            stakedId,
            amount,
            ""
        );
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
        uint256 pending = (user.amount * accRewardPerShare) /
            ACC_PRECISION -
            user.rewardDebt;
        if (pending > 0) {
            pending = _safePay(pending);
            if (pending > 0) emit Claimed(msg.sender, pending);
        }
        user.amount -= amount;
        totalStaked -= amount;
        user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
        stakedToken.safeTransferFrom(
            address(this),
            msg.sender,
            stakedId,
            amount,
            ""
        );
        emit Unstaked(msg.sender, amount);
    }

    function claim() external nonReentrant whenNotPaused {
        _syncBudget();
        UserInfo storage user = users[msg.sender];
        uint256 pending = (user.amount * accRewardPerShare) /
            ACC_PRECISION -
            user.rewardDebt;
        if (pending > 0) {
            uint256 paid = _safePay(pending);
            user.rewardDebt = (user.amount * accRewardPerShare) / ACC_PRECISION;
            if (paid > 0) emit Claimed(msg.sender, paid);
        }
    }

    /// @dev Caps `amount` at the on-chain reward balance and transfers to
    ///      msg.sender. Returns the amount actually paid. Necessary because
    ///      per-user floor rounding in (amount * acc / ACC_PRECISION) can in
    ///      rare cases cumulatively exceed rewardBudget by 1 wei across many
    ///      accruals; the on-chain balance is the hard cap.
    function _safePay(uint256 amount) internal returns (uint256) {
        uint256 balance = rewardToken.balanceOf(address(this));
        uint256 paid = amount > balance ? balance : amount;
        if (paid > 0) {
            rewardToken.safeTransfer(msg.sender, paid);
        }
        return paid;
    }

    /// @notice Withdraw the caller's full principal in a single ERC1155
    ///         transfer, forfeiting any pending reward. Callable while paused
    ///         and does NOT call `_syncBudget` / `_updatePool`, so a broken
    ///         dispatcher hook can never trap principal. Standard masterchef
    ///         escape hatch.
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = users[msg.sender];
        uint256 amount = user.amount;
        require(amount > 0, "NFTStaker: nothing to withdraw");
        user.amount = 0;
        user.rewardDebt = 0;
        totalStaked -= amount;
        stakedToken.safeTransferFrom(
            address(this),
            msg.sender,
            stakedId,
            amount,
            ""
        );
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function pendingReward(address account) external view returns (uint256) {
        UserInfo memory user = users[account];
        uint256 acc = accRewardPerShare;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 end = block.timestamp < windowEnd
                ? block.timestamp
                : windowEnd;
            uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
            uint256 reward = elapsed * rewardRate;
            if (reward > rewardBudget) reward = rewardBudget;
            acc += (reward * ACC_PRECISION) / totalStaked;
        }
        return (user.amount * acc) / ACC_PRECISION - user.rewardDebt;
    }

    function currentRewardRate() external view returns (uint256) {
        if (block.timestamp >= windowEnd) return 0;
        return rewardRate;
    }

    /// @notice Tokens currently owed to stakers: accrued rewards not yet
    ///         claimed, including in-flight accrual since `lastRewardTime`.
    ///         Derived from the invariant
    ///         `balance == rewardBudget + totalDebt` (plus bounded
    ///         floor-division dust in protocol's favor).
    function totalDebt() external view returns (uint256) {
        uint256 budget = rewardBudget;
        if (block.timestamp > lastRewardTime && totalStaked > 0) {
            uint256 end = block.timestamp < windowEnd
                ? block.timestamp
                : windowEnd;
            uint256 elapsed = end > lastRewardTime ? end - lastRewardTime : 0;
            uint256 reward = elapsed * rewardRate;
            if (reward > budget) reward = budget;
            budget -= reward;
        }
        uint256 balance = rewardToken.balanceOf(address(this));
        return balance > budget ? balance - budget : 0;
    }

    /// @notice All phUSD the pool controls: held balance plus phUSD still
    ///         claimable from the dispatcher hook via `pull()`.
    function totalBudget() external view returns (uint256) {
        uint256 pending = address(dispatcherHook) == address(0)
            ? 0
            : dispatcherHook.mintDebt();
        return rewardToken.balanceOf(address(this)) + pending;
    }

    /// @notice Seconds of emissions remaining at the current `rewardRate`,
    ///         counting both on-contract budget and pending hook mint debt.
    ///         Returns 0 when the rate is zero.
    function runwaySeconds() external view returns (uint256) {
        if (rewardRate == 0) return 0;
        uint256 pending = address(dispatcherHook) == address(0)
            ? 0
            : dispatcherHook.mintDebt();
        return (rewardBudget + pending) / rewardRate;
    }
}
