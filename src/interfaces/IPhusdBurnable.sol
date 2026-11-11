// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice phUSD (a FlaxToken instance) allowance-based burn. `burn` spends `msg.sender`'s
///         allowance over `holder` (transferFrom-style) then reduces supply. Ungated by role.
/// @dev    Minimal local copy of yield-claim-nft `src/interfaces/IPhusdBurnable.sol`, which is
///         not part of the vendored `lib/mutable/yield-claim-nft` interface set.
interface IPhusdBurnable {
    function burn(address holder, uint256 amount) external;
}
