// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  INFTStakerMigratable
/// @notice Minimal receive surface of `NFTStakerDepletion` that the migration
///         orchestrators (`NFTStakerMigrator`, `InPlaceNFTStakerMigrator`)
///         depend on. The nft-staking analogue of `IStableStaker`.
/// @dev    Kept intentionally small so the migrators stay decoupled from the
///         full staker implementation. The permissioned functions
///         (`initiateMigration`, `batchMigrate`, `depositFor`) are gated by
///         `onlyMigrator` on the staker.
///
///         KEY DIFFERENCE vs `IStableStaker`: the staked "principal" is an
///         ERC1155 position (a balance of a single `stakedId`), NOT a fungible
///         ERC20 amount. Migration therefore moves ERC1155 stake (+ settles
///         pending phUSD reward) rather than transferring fungible principal.
///         There is no (R, P) realized/principal snapshot or uniform haircut —
///         the Uniboost staker has no external yield strategy that can go
///         underwater, so `batchMigrate` returns each user's exact staked
///         amount.
interface INFTStakerMigratable {
    /// @notice Settle in-flight accrual and freeze emissions, flipping the pool
    ///         into the `Migrating` state. No strategy unwind — the Uniboost
    ///         staker's budget is idle rewardToken + hook mint-debt. Must be
    ///         called exactly once before any `batchMigrate`.
    /// @dev    Permissioned (`onlyMigrator` on the staker). Reverts if the pool
    ///         is already migrating.
    function initiateMigration() external;

    /// @notice Permissioned, batched migration exit. For each user: settles and
    ///         mints their pending phUSD reward, zeroes their position, and
    ///         transfers their staked ERC1155 amount (of `stakedId`) to the
    ///         caller (the migrator). Requires a prior `initiateMigration`.
    /// @param  users The users to migrate out.
    /// @return amounts Per-user staked ERC1155 amount, parallel to `users`
    ///         (0 for empty / already-migrated positions). Idempotent: a re-run
    ///         returns 0 for an already-zeroed position.
    function batchMigrate(address[] calldata users) external returns (uint256[] memory amounts);

    /// @notice Permissioned deposit crediting `user` with `amount` ERC1155
    ///         units pulled from the caller (the migrator). Only valid while the
    ///         pool is `Active`, so it credits the new/healthy staker, never the
    ///         frozen one.
    /// @param  user   The user to credit.
    /// @param  amount The ERC1155 stake amount to deposit on the user's behalf.
    function depositFor(address user, uint256 amount) external;

    /// @notice Read-only auto-getter for the staker's public `users` mapping.
    ///         Returns `user`'s currently-credited position.
    /// @param  user The user whose position to read.
    /// @return amount     The user's credited ERC1155 stake.
    /// @return rewardDebt The user's reward-debt bookkeeping value.
    function userInfo(address user) external view returns (uint256 amount, uint256 rewardDebt);
}
