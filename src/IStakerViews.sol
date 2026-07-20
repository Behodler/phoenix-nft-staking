// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  IStakerViews
/// @notice Minimal local view of the two public staker accessors the migrators
///         need for settlement-capture forwarding: the reward-token auto-getter
///         and the `pendingReward` projection.
///
/// @dev    WHY THIS IS NOT ON `INFTStakerMigratable` (plan decision D-5):
///         `INFTStakerMigratable` is the deliberately-minimal migration
///         contract between a staker and its orchestrator — `initiateMigration`,
///         `batchMigrate`, `depositFor`. `rewardToken()` and
///         `pendingReward(address)` are not part of that contract; they are
///         incidental public getters that happen to exist on every migration-
///         capable staker. Widening the shared interface would force a change
///         on every implementer for what is purely a migrator-local concern, so
///         the migrators declare this narrow extension and cast to it instead.
///
///         Both migration-capable stakers satisfy this shape today:
///         `NFTStakerDepletion` (`rewardToken` at :95, `pendingReward` at :799)
///         and `NFTStakerPriceScaledMigrateReady` (:116 / :947).
interface IStakerViews {
    /// @notice The ERC20 the staker emits (phUSD).
    function rewardToken() external view returns (IERC20);

    /// @notice The reward `account` would be settled if it interacted with the
    ///         staker at the current block timestamp.
    function pendingReward(address account) external view returns (uint256);
}
