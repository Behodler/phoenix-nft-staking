// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";
import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/V2/interfaces/IBalancerPoolerMintDebtHook.sol";

/// @title  NFTStaker
/// @notice Masterchef-style staking pool for a single ERC1155 token ID.
///         Stakers deposit ERC1155 units of `stakedId` and earn per-second
///         emissions of `rewardToken` (phUSD). The reward budget is funded
///         by `pull()`-ing accrued mint debt from the configured dispatcher
///         hook plus owner top-ups. See `docs/design.md` (in the
///         product-owner repo) for the full design rationale.
contract NFTStaker is Ownable, Pausable, ReentrancyGuard, ERC1155Holder, IPausable {
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

    uint64 public lastRewardTime;
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
    event Pulled(uint256 inflow, uint256 newBudget, uint256 newRate, uint256 newWindowEnd);
    event ToppedUp(address indexed from, uint256 amount, uint256 newBudget, uint256 newRate);
    event WindowDurationChanged(uint256 previous, uint256 next);
    event DispatcherHookChanged(address indexed previous, address indexed next);
    event StakedIdChanged(uint256 previous, uint256 next);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyPauser() {
        require(msg.sender == pauser, "NFTStaker: caller is not pauser");
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IERC1155 _stakedToken, uint256 _stakedId, IERC20 _rewardToken, address _initialOwner)
        Ownable(_initialOwner)
    {
        require(address(_stakedToken) != address(0), "NFTStaker: zero staked token");
        require(address(_rewardToken) != address(0), "NFTStaker: zero reward token");
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

    function setDispatcherHook(IBalancerPoolerMintDebtHook newHook) external onlyOwner {
        emit DispatcherHookChanged(address(dispatcherHook), address(newHook));
        dispatcherHook = newHook;
    }

    function setStakedId(uint256 newId) external onlyOwner {
        require(totalStaked == 0, "NFTStaker: stake outstanding");
        emit StakedIdChanged(stakedId, newId);
        stakedId = newId;
    }

    function setWindowDuration(uint256 newDuration) external onlyOwner {
        require(newDuration >= MIN_WINDOW && newDuration <= MAX_WINDOW, "NFTStaker: window out of bounds");
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

    /// @dev Stub for the accrual settle step. Wired up properly in Phase 3.
    function _updatePool() internal {
        if (block.timestamp <= lastRewardTime) return;
        if (totalStaked == 0) {
            lastRewardTime = uint64(block.timestamp);
            return;
        }
        // Phase 3 fills in the accrual maths.
    }

    // ---------------------------------------------------------------------
    // User entrypoints (stubbed)
    // ---------------------------------------------------------------------

    function stake(
        uint256 /*amount*/
    )
        external
    {
        revert("not impl");
    }

    function unstake(
        uint256 /*amount*/
    )
        external
    {
        revert("not impl");
    }

    function claim() external {
        revert("not impl");
    }

    function emergencyWithdraw() external {
        revert("not impl");
    }

    // ---------------------------------------------------------------------
    // Views (stubbed)
    // ---------------------------------------------------------------------

    function pendingReward(
        address /*user*/
    )
        external
        view
        returns (uint256)
    {
        revert("not impl");
    }

    function currentRewardRate() external view returns (uint256) {
        revert("not impl");
    }
}
