// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  INFTSupply
/// @notice Minimal interface combining the `ERC1155Supply.totalSupply(uint256)`
///         and `NFTMinterV2.configs(uint256)` reads that `NFTStaker` depends
///         on to compute its APY-driven emission schedule.
///
///         Declared locally so `NFTStaker` does not reach across into the
///         sibling `yield-claim-nft` submodule (which exposes
///         `INFTMinterV2` but does not re-declare `totalSupply(uint256)` on
///         the interface). This keeps the sibling boundary clean — no
///         cross-submodule change request needed.
///
///         `NFTMinterV2` — the concrete implementation — inherits OpenZeppelin
///         `ERC1155Supply` and implements `configs`, so the production wiring
///         of `INFTSupply` is a direct cast of the deployed `NFTMinterV2`
///         address.
interface INFTSupply {
    /// @notice Total ERC1155 supply for a given token ID.
    /// @dev    Provided by OpenZeppelin `ERC1155Supply` on the concrete
    ///         `NFTMinterV2`.
    /// @param  id The token ID.
    /// @return The total supply of `id` across all holders.
    function totalSupply(uint256 id) external view returns (uint256);

    /// @notice Dispatcher configuration by index.
    /// @param  index The dispatcher index (1-based in `NFTMinterV2`).
    /// @return dispatcher The dispatcher contract address.
    /// @return price The NEXT mint price; incremented after every mint by
    ///              `price + price * growthBasisPoints / 10_000`.
    /// @return growthBasisPoints Per-mint price growth in basis points.
    /// @return disabled Whether minting is disabled for this dispatcher.
    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled);
}
