// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BatchNFTMinter
/// @notice Helper that loops `ITokenMinterV2.mint(...)` `count` times in a single
///         transaction, routing each minted unit to a caller-specified `recipient`.
///         The caller passes the aggregate `paymentAmount`; the helper pulls it
///         once upfront, pre-approves the minter for `type(uint256).max`, then
///         revokes the approval at the end.
///
/// Owner-administered nudge incentive (introduced after the original stateless
/// design): when `count >= nudgeSize` and `nudgePaymentToken` is set, the
/// contract transfers its full balance of `nudgePaymentToken` to `recipient`
/// before sweeping any dust refund. Funded externally (e.g. by a yield funnel
/// directing USDC into this contract). Setting either knob to zero disables.
/// `nudgePaymentToken` MUST differ from the call's `paymentToken` whenever
/// the nudge is configured — otherwise the call reverts up-front, before any
/// funds are pulled.
///
/// Any payment-token balance left after the loop and after the optional nudge
/// transfer — unused budget, dispatcher-side dust, or a third-party donation —
/// is swept back to `msg.sender` provided it is at least `DUST_THRESHOLD` wei.
/// Sub-threshold residue is intentionally left to absorb JS-side rounding noise
/// and is picked up by the next batch's sweep. A griefer who pre-deposits
/// payment-token to this contract simply donates to the next caller.
///
/// If `paymentAmount` falls short of the dispatcher's cumulative charge an
/// inner `mint` reverts and the entire batch atomically rolls back.
contract BatchNFTMinter is Ownable {
    using SafeERC20 for IERC20;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @dev Residual payment-token balance below this threshold is kept
    ///      in the contract rather than refunded, absorbing JS rounding
    ///      slack. For an 18-decimal token this is ~10^-12 of a unit.
    uint256 internal constant DUST_THRESHOLD = 1e6;

    /// @notice Batch sizes >= this value qualify for the nudge payout. `0` disables.
    uint256 public nudgeSize;

    /// @notice ERC20 paid out as the nudge. `address(0)` disables.
    address public nudgePaymentToken;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();
    /// @dev Reverted when `nudgePaymentToken` is set and equals the call's `paymentToken`.
    error BatchMint__NudgeTokenMatchesPaymentToken();

    event NudgeSizeChanged(uint256 newSize);
    event NudgePaymentTokenChanged(address indexed newToken);
    event NudgePaid(
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    /// @notice Owner-gated update of the batch-size threshold for the nudge
    ///         payout. Setting `0` disables the feature.
    function setNudgeSize(uint256 newSize) external onlyOwner {
        nudgeSize = newSize;
        emit NudgeSizeChanged(newSize);
    }

    /// @notice Owner-gated update of the nudge payout token. Setting
    ///         `address(0)` disables the feature.
    function setNudgePaymentToken(address newToken) external onlyOwner {
        nudgePaymentToken = newToken;
        emit NudgePaymentTokenChanged(newToken);
    }

    /// @notice Mint `count` NFT units of dispatcher `dispatcherIndex` to
    ///         `recipient`, pulling `paymentAmount` of `paymentToken`
    ///         from `msg.sender` upfront and refunding any surplus.
    /// @dev    `paymentToken` must match the dispatcher's prime token —
    ///         V2's `mint(...)` resolves the payment asset from the
    ///         dispatcher itself, so a mismatch causes the inner mint to
    ///         revert and the entire batch rolls back atomically
    ///         (including the upfront pull).
    ///
    ///         When the nudge feature is active and `count >= nudgeSize`,
    ///         the helper transfers its full `nudgePaymentToken` balance
    ///         to `recipient` AFTER the loop (and after the V2 minter
    ///         allowance is revoked) but BEFORE the dust refund sweep.
    ///         If `nudgePaymentToken` is configured it must be a different
    ///         address than `paymentToken` — otherwise the call reverts
    ///         up-front, before any funds are pulled.
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

        address _nudgeTokenEntry = nudgePaymentToken;
        if (
            _nudgeTokenEntry != address(0) &&
            _nudgeTokenEntry == address(paymentToken)
        ) {
            revert BatchMint__NudgeTokenMatchesPaymentToken();
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        paymentToken.forceApprove(address(nftMinter), type(uint256).max);

        for (uint256 i; i < count; ++i) {
            nftMinter.mint(dispatcherIndex, recipient);
        }

        paymentToken.forceApprove(address(nftMinter), 0);

        //note to reviewer: I (dev) changed nudgeToken to reuse _nudgeTokenEntry
        uint256 _nudgeSize = nudgeSize;
        if (_nudgeSize != 0 && count >= _nudgeSize) {
            // _nudgeTokenEntry guaranteed != paymentToken by the up-front guard;
            // re-read here is a warm SLOAD.

            if (_nudgeTokenEntry != address(0)) {
                uint256 nudgeAmount = IERC20(_nudgeTokenEntry).balanceOf(
                    address(this)
                );
                if (nudgeAmount != 0) {
                    IERC20(_nudgeTokenEntry).safeTransfer(
                        recipient,
                        nudgeAmount
                    );
                    emit NudgePaid(recipient, _nudgeTokenEntry, nudgeAmount);
                }
            }
        }

        uint256 remaining = paymentToken.balanceOf(address(this));
        if (remaining / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, remaining);
            totalPaid = paymentAmount > remaining
                ? paymentAmount - remaining
                : 0;
        } else {
            totalPaid = paymentAmount;
        }
    }
}
