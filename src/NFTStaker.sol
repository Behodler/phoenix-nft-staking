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

    function setDispatcherHook(
        IBalancerPoolerMintDebtHook /*newHook*/
    )
        external
        onlyOwner
    {
        revert("not impl");
    }

    function setStakedId(
        uint256 /*newId*/
    )
        external
        onlyOwner
    {
        revert("not impl");
    }

    function setWindowDuration(
        uint256 /*newDuration*/
    )
        external
        onlyOwner
    {
        revert("not impl");
    }

    function topUp(
        uint256 /*amount*/
    )
        external
        onlyOwner
    {
        revert("not impl");
    }

    function pullAndRefresh() external {
        revert("not impl");
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
