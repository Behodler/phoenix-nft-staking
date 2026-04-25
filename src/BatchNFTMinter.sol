// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinter} from "yield-claim-nft/interfaces/ITokenMinter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BatchNFTMinter
/// @notice Stateless helper that loops `ITokenMinter.mint(...)` `count`
///         times in a single transaction, routing each minted unit to a
///         caller-specified `recipient`. The cumulative cost is pulled
///         from `msg.sender` per iteration and forwarded to the
///         dispatcher via the standard mint flow on `nftMinter`.
///
/// The contract holds no state between calls and intentionally does not
/// implement reentrancy guards, ownership, or pausing — it is a pure
/// utility wrapper. If any inner mint reverts, the entire batch reverts
/// atomically. See the story checklist (009-batch-nft-mint-helper) for
/// the full design rationale and intentional non-features.
contract BatchNFTMinter {
    using SafeERC20 for IERC20;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();

    /// @notice Mint `count` NFT units of dispatcher `dispatcherIndex` to
    ///         `recipient`, paying with `paymentToken` pulled from
    ///         `msg.sender` at each iteration's live price.
    /// @param  nftMinter        The NFT minter to forward each `mint` to.
    /// @param  paymentToken     ERC20 used to pay for each mint.
    /// @param  dispatcherIndex  Dispatcher index registered with `nftMinter`.
    /// @param  count            Number of mints (>0).
    /// @param  recipient        ERC1155 recipient (non-zero).
    /// @return totalPaid        Sum of `paymentToken` pulled across all iterations.
    function batchMint(
        ITokenMinter nftMinter,
        IERC20 paymentToken,
        uint256 dispatcherIndex,
        uint256 count,
        address recipient
    ) external returns (uint256 totalPaid) {
        if (count == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();

        for (uint256 i; i < count; ++i) {
            uint256 price = nftMinter.getPrice(dispatcherIndex);
            paymentToken.safeTransferFrom(msg.sender, address(this), price);
            paymentToken.forceApprove(address(nftMinter), price);
            nftMinter.mint(address(paymentToken), dispatcherIndex, recipient);
            totalPaid += price;
        }
    }
}
