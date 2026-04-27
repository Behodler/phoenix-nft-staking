// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title BatchNFTMinter
/// @notice Stateless helper that loops `ITokenMinterV2.mint(...)` `count`
///         times in a single transaction, routing each minted unit to a
///         caller-specified `recipient`. The caller passes the aggregate
///         `paymentAmount` they expect to spend; the helper pulls it
///         once upfront, pre-approves the minter for `type(uint256).max`
///         so the dispatcher can draw each mint's price from this
///         contract's balance, and revokes the approval at the end.
///
/// Any payment-token balance left on this contract after the loop —
/// unused budget, dispatcher-side dust, or a third-party donation — is
/// swept back to `msg.sender` provided it is at least `DUST_THRESHOLD`
/// wei. Sub-threshold residue is intentionally left to absorb
/// JavaScript-side rounding noise and is picked up by the next batch's
/// sweep. A griefer who pre-deposits payment-token to this contract
/// simply donates to the next caller; the contract's balance always
/// flows forward to whoever invokes `batchMint` next.
///
/// If `paymentAmount` falls short of the dispatcher's cumulative charge
/// an inner `mint` reverts and the entire batch atomically rolls back.
/// The contract holds no state between calls and intentionally does not
/// implement reentrancy guards, ownership, or pausing.
contract BatchNFTMinter {
    using SafeERC20 for IERC20;

    /// @dev Residual payment-token balance below this threshold is kept
    ///      in the contract rather than refunded, absorbing JS rounding
    ///      slack. For an 18-decimal token this is ~10^-12 of a unit.
    uint256 internal constant DUST_THRESHOLD = 1e6;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();

    /// @notice Mint `count` NFT units of dispatcher `dispatcherIndex` to
    ///         `recipient`, pulling `paymentAmount` of `paymentToken`
    ///         from `msg.sender` upfront and refunding any surplus.
    /// @dev    `paymentToken` must match the dispatcher's prime token —
    ///         V2's `mint(...)` resolves the payment asset from the
    ///         dispatcher itself, so a mismatch causes the inner mint to
    ///         revert and the entire batch rolls back atomically
    ///         (including the upfront pull).
    /// @param  nftMinter        The NFT minter to forward each `mint` to.
    /// @param  paymentToken     ERC20 used to pay for each mint.
    /// @param  dispatcherIndex  Dispatcher index registered with `nftMinter`.
    /// @param  count            Number of mints (>0).
    /// @param  recipient        ERC1155 recipient (non-zero).
    /// @param  paymentAmount    Total payment-token to pull upfront.
    ///                          Must cover the dispatcher's cumulative
    ///                          cost across `count` iterations or an
    ///                          inner mint reverts. Surplus >=
    ///                          `DUST_THRESHOLD` is refunded.
    /// @return totalPaid        Caller's net spend (`paymentAmount`
    ///                          minus any refunded surplus).
    function batchMint(
        ITokenMinterV2 nftMinter,
        IERC20 paymentToken,
        uint256 dispatcherIndex,
        uint256 count,
        address recipient,
        uint256 paymentAmount
    ) external returns (uint256 totalPaid) {
        if (count == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        paymentToken.forceApprove(address(nftMinter), type(uint256).max);

        for (uint256 i; i < count; ++i) {
            nftMinter.mint(dispatcherIndex, recipient);
        }

        paymentToken.forceApprove(address(nftMinter), 0);

        uint256 remaining = paymentToken.balanceOf(address(this));
        if (remaining / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, remaining);
            totalPaid = paymentAmount > remaining ? paymentAmount - remaining : 0;
        } else {
            totalPaid = paymentAmount;
        }
    }
}
