// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {INFTStakerMigratable} from "./INFTStakerMigratable.sol";

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
contract NFTStakerMigrator is Ownable, ERC1155Holder {
    /// @notice The staker users are migrating out of.
    INFTStakerMigratable public immutable oldStaker;

    /// @notice The staker users are migrating into.
    INFTStakerMigratable public immutable newStaker;

    /// @notice The shared ERC1155 stake token (must match on both stakers).
    IERC1155 public immutable stakedToken;

    /// @notice The shared ERC1155 stake ID (must match on both stakers).
    uint256 public immutable stakedId;

    event Migrated(uint256 userCount, uint256 totalAmount);

    constructor(
        INFTStakerMigratable _oldStaker,
        INFTStakerMigratable _newStaker,
        IERC1155 _stakedToken,
        uint256 _stakedId,
        address initialOwner
    ) Ownable(initialOwner) {
        require(address(_oldStaker) != address(0), "Migrator: zero old staker");
        require(address(_newStaker) != address(0), "Migrator: zero new staker");
        require(address(_stakedToken) != address(0), "Migrator: zero staked token");
        require(address(_oldStaker) != address(_newStaker), "Migrator: same staker");
        oldStaker = _oldStaker;
        newStaker = _newStaker;
        stakedToken = _stakedToken;
        stakedId = _stakedId;
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
    /// @param  users The users to migrate (batched off-chain).
    function migrate(address[] calldata users) external onlyOwner {
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
                newStaker.depositFor(users[i], amounts[i]);
                migratedCount++;
            }
        }

        // Revoke the operator approval — nothing should linger.
        stakedToken.setApprovalForAll(address(newStaker), false);

        emit Migrated(migratedCount, total);
    }
}
