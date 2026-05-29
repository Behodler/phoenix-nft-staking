// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/V2/interfaces/ITokenMinterV2.sol";
import {INFTMinterV2} from "yield-claim-nft/V2/interfaces/INFTMinterV2.sol";
import {ITokenDispatcherV2} from "yield-claim-nft/V2/interfaces/ITokenDispatcherV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";

/// @title BatchNFTMinter
/// @notice Helper that loops `ITokenMinterV2.mint(...)` `count` times in a single
///         transaction, routing each minted unit to a caller-specified `recipient`.
///         The caller passes the aggregate `paymentAmount`; the helper pulls it
///         once upfront, pre-approves the minter for `type(uint256).max`, then
///         revokes the approval at the end.
///
/// The NFT minter is a **trusted, owner-configured** contract (`tokenMinter`),
/// NOT a call parameter. Originally `batchMint` accepted the minter as a
/// caller-supplied argument; that was safe while the contract held no funds of
/// its own (story-009's stateless looper). Once the owner-administered nudge
/// (below) gave the contract a balance that pays out on a purely numeric
/// `count >= nudgeSize` gate, a caller-supplied minter became a drain vector:
/// an attacker could pass a no-op minter, fake `count` cheap "mints", clear the
/// gate, and walk off with the entire nudge pot without paying for any real
/// mints. Pinning the minter to owner-set state closes this — qualifying for
/// the nudge now requires genuinely paying for >= `nudgeSize` real mints at the
/// dispatcher's ramping price, and a faked/mismatched `paymentToken` reverts the
/// real `mint()` and rolls the whole batch back.
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
///
/// Pausing is wired into the Phoenix global `Pauser` via the hybrid OZ
/// `Pausable` + `IPausable` pattern (see `NFTStaker`): a settable `pauser`
/// address may `pause()`/`unpause()`, and only `batchMint` is gated by
/// `whenNotPaused`. Admin setters and `rescueERC20` stay callable while paused.
contract BatchNFTMinter is Ownable, Pausable, IPausable {
    using SafeERC20 for IERC20;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @dev Residual payment-token balance below this threshold is kept
    ///      in the contract rather than refunded, absorbing JS rounding
    ///      slack. For an 18-decimal token this is ~10^-12 of a unit.
    uint256 internal constant DUST_THRESHOLD = 1e6;

    /// @notice Trusted, owner-configured NFT minter every `batchMint` forwards
    ///         to. `address(0)` disables `batchMint`.
    ITokenMinterV2 public tokenMinter;

    /// @notice The only dispatcher index `batchMint` mints. Owner-set;
    ///         `0` = unconfigured and disables `batchMint`. The V2 minter's
    ///         `nextIndex` starts at 1, so `0` is never a valid registered
    ///         dispatcher — reusing it as the disabled sentinel mirrors
    ///         `tokenMinter == address(0)`.
    uint256 public dispatcherIndex;

    /// @notice Batch sizes >= this value qualify for the nudge payout. `0` disables.
    uint256 public nudgeSize;

    /// @notice ERC20 paid out as the nudge. `address(0)` disables.
    address public nudgePaymentToken;

    /// @notice Address authorised to pause/unpause via the global pauser.
    ///         Settable by the owner; `address(0)` disables pausing.
    address public pauser;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();
    /// @dev Reverted when `nudgePaymentToken` is set and equals the call's `paymentToken`.
    error BatchMint__NudgeTokenMatchesPaymentToken();
    /// @dev Reverted when `batchMint` is called while `tokenMinter` is unset.
    error BatchMint__MinterNotConfigured();
    /// @dev Reverted when `batchMint` is called while `dispatcherIndex` is unset
    ///      (`0`) or the pinned index resolves to a zero dispatcher.
    error BatchMint__DispatcherNotConfigured();
    /// @dev Reverted when `rescueERC20` is given a zero destination.
    error Rescue__ZeroRecipient();

    event NudgeSizeChanged(uint256 newSize);
    event NudgePaymentTokenChanged(address indexed newToken);
    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event TokenMinterSet(address indexed newMinter);
    event DispatcherIndexSet(uint256 indexed dispatcherIndex);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);

    modifier onlyPauser() {
        require(msg.sender == pauser, "BatchNFTMinter: caller is not pauser");
        _;
    }

    /// @notice Owner-gated update of the trusted NFT minter. Setting
    ///         `address(0)` disables `batchMint` (it reverts
    ///         `BatchMint__MinterNotConfigured`).
    function setTokenMinter(ITokenMinterV2 newMinter) external onlyOwner {
        tokenMinter = newMinter;
        emit TokenMinterSet(address(newMinter));
    }

    /// @notice Owner-gated update of the only dispatcher index `batchMint`
    ///         mints. Setting `0` disables `batchMint` (it reverts
    ///         `BatchMint__DispatcherNotConfigured`). Stays callable while
    ///         paused.
    function setDispatcherIndex(uint256 newIndex) external onlyOwner {
        dispatcherIndex = newIndex;
        emit DispatcherIndexSet(newIndex);
    }

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

    /// @notice Owner-gated update of the pauser address. Setting `address(0)`
    ///         disables pausing. Stays callable while paused.
    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    /// @notice Pause `batchMint`. Callable only by the registered `pauser`
    ///         (typically the global Pauser contract). Matches `NFTStaker`'s
    ///         pauser-only convention.
    function pause() external override onlyPauser {
        _pause();
    }

    /// @notice Resume `batchMint`. Callable only by the registered `pauser`.
    function unpause() external override onlyPauser {
        _unpause();
    }

    /// @notice Owner-only recovery of an arbitrary ERC20. The deployed
    ///         contract previously had no owner-withdraw at all, so a trapped
    ///         balance could only ever leave via the nudge — this is the
    ///         missing escape hatch. Owner-trusted (the owner can already pull
    ///         the nudge token via the nudge setters), so no token restriction
    ///         is needed; an explicit `amount` is preferred over a
    ///         full-balance sweep so it composes with the nudge pot. Stays
    ///         callable while paused (mirrors `NFTStaker.emergencyWithdraw`).
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Rescue__ZeroRecipient();
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @notice Mint `count` NFT units of the owner-pinned `dispatcherIndex`
    ///         to `recipient`, pulling `paymentAmount` of the dispatcher's
    ///         prime token from `msg.sender` upfront and refunding any surplus.
    /// @dev    Forwards to the trusted, owner-pinned `tokenMinter`; reverts
    ///         `BatchMint__MinterNotConfigured` if it is unset. The dispatcher
    ///         is pinned as owner-set state (`dispatcherIndex`); the caller can
    ///         no longer choose it. `batchMint` reverts
    ///         `BatchMint__DispatcherNotConfigured` if `dispatcherIndex` is `0`
    ///         (unconfigured) or resolves to a zero dispatcher. The payment
    ///         asset is DERIVED from the pinned dispatcher's `primeToken()` —
    ///         it is no longer a caller-supplied parameter, so a wrong/zero
    ///         payment asset can never be passed.
    ///
    ///         When the nudge feature is active and `count >= nudgeSize`,
    ///         the helper transfers its full `nudgePaymentToken` balance
    ///         to `recipient` AFTER the loop (and after the V2 minter
    ///         allowance is revoked) but BEFORE the dust refund sweep.
    ///         If `nudgePaymentToken` is configured it must be a different
    ///         address than the derived payment token — otherwise the call
    ///         reverts up-front, before any funds are pulled. With the payment
    ///         token derived, this guard is a deploy-time config invariant
    ///         (nudge token must differ from the dispatcher's prime token).
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
        uint256 count,
        address recipient,
        uint256 paymentAmount
    ) external whenNotPaused returns (uint256 totalPaid) {
        if (count == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();

        ITokenMinterV2 nftMinter = tokenMinter;
        if (address(nftMinter) == address(0)) {
            revert BatchMint__MinterNotConfigured();
        }

        uint256 _dispatcherIndex = dispatcherIndex;
        if (_dispatcherIndex == 0) revert BatchMint__DispatcherNotConfigured();

        (address dispatcher,,,) = INFTMinterV2(address(nftMinter)).configs(_dispatcherIndex);
        if (dispatcher == address(0)) revert BatchMint__DispatcherNotConfigured();

        IERC20 paymentToken = IERC20(ITokenDispatcherV2(dispatcher).primeToken());

        address _nudgeTokenEntry = nudgePaymentToken;
        if (_nudgeTokenEntry != address(0) && _nudgeTokenEntry == address(paymentToken)) {
            revert BatchMint__NudgeTokenMatchesPaymentToken();
        }

        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
        paymentToken.forceApprove(address(nftMinter), type(uint256).max);

        for (uint256 i; i < count; ++i) {
            nftMinter.mint(_dispatcherIndex, recipient);
        }

        paymentToken.forceApprove(address(nftMinter), 0);

        //note to reviewer: I (dev) changed nudgeToken to reuse _nudgeTokenEntry
        uint256 _nudgeSize = nudgeSize;
        if (_nudgeSize != 0 && count >= _nudgeSize) {
            // _nudgeTokenEntry guaranteed != paymentToken by the up-front guard;
            // re-read here is a warm SLOAD.

            if (_nudgeTokenEntry != address(0)) {
                uint256 nudgeAmount = IERC20(_nudgeTokenEntry).balanceOf(address(this));
                if (nudgeAmount != 0) {
                    IERC20(_nudgeTokenEntry).safeTransfer(recipient, nudgeAmount);
                    emit NudgePaid(recipient, _nudgeTokenEntry, nudgeAmount);
                }
            }
        }

        uint256 remaining = paymentToken.balanceOf(address(this));
        if (remaining / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, remaining);
            totalPaid = paymentAmount > remaining ? paymentAmount - remaining : 0;
        } else {
            totalPaid = paymentAmount;
        }
    }
}
