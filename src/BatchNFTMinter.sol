// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {INFTMinterV2} from "yield-claim-nft/interfaces/INFTMinterV2.sol";
import {ITokenDispatcherV2} from "yield-claim-nft/interfaces/ITokenDispatcherV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
/// its own (story-009's stateless looper). Once the nudge incentive (below)
/// gave the contract a balance that pays out on a purely numeric
/// `count >= nudgeSize` gate, a caller-supplied minter became a drain vector:
/// an attacker could pass a no-op minter, fake `count` cheap "mints", clear the
/// gate, and walk off with the entire nudge pot without paying for any real
/// mints. Pinning the minter to owner-set state closes this — qualifying for
/// the nudge now requires genuinely paying for >= `nudgeSize` real mints at the
/// dispatcher's ramping price, and a faked/mismatched `paymentToken` reverts the
/// real `mint()` and rolls the whole batch back.
///
/// ### Caller-selected multi-token nudge
///
/// The owner controls **eligibility** and nothing else. `nudgeSize` gates *who*
/// qualifies (batch size >= threshold; `0` disables the feature outright). The
/// **caller** declares *which* ERC20 balances held by this contract they want
/// to be paid in, via the `rewardTokens` array, together with a per-token
/// `minRewards` floor. A qualifying caller receives this contract's entire
/// **pre-loop** balance of every listed token.
///
/// Two consequences of that design, both intended:
///
/// - **Permissionless top-up.** Anyone can seed the batch incentive with any
///   ERC20 simply by sending it here. No owner transaction is involved.
/// - **Exogenous reward capture.** A caller (or bot) that enumerates this
///   contract's balances can claim tokens no official UI lists. Deliberate:
///   unclaimed value should not be stranded.
///
/// @dev **WARNING — tokens sent to this contract may be claimed by anyone who
///      qualifies.** This contract makes NO promise that arbitrary ERC20s
///      transferred to it are recoverable. Any balance it holds (other than the
///      dispatcher's payment token, which is excluded by an explicit guard) can
///      be swept in full by the next caller who clears the `nudgeSize` gate and
///      lists that token. Do not use this address as custody. The "honeypot"
///      framing does not apply, because the pot is by construction a fraction of
///      the cost of the `nudgeSize` mints required to qualify — every claim is
///      net-positive for the protocol. If someone over-funds this contract
///      beyond the mint cost and a bot snipes it, that is still correct
///      behaviour; the error was in the sender.
///
/// Any payment-token balance left after the loop and after the optional nudge
/// transfers — unused budget, dispatcher-side dust, or a third-party donation —
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
///
/// `ReentrancyGuard` is required rather than optional: `rewardTokens` are
/// caller-supplied addresses this contract calls twice (`balanceOf` and
/// `transfer`), so the payout pass is an arbitrary-code hook the caller
/// controls. See the note on `batchMint`.
contract BatchNFTMinter is Ownable, Pausable, ReentrancyGuard, IPausable {
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

    /// @notice Batch sizes >= this value qualify for the nudge payout. `0`
    ///         disables the incentive entirely. This is the owner's ONLY lever
    ///         over the nudge — the reward asset itself is caller-selected.
    uint256 public nudgeSize;

    /// @notice Address authorised to pause/unpause via the global pauser.
    ///         Settable by the owner; `address(0)` disables pausing.
    address public pauser;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();
    /// @dev Reverted when a `rewardTokens` element equals the dispatcher's
    ///      derived payment token. Fires unconditionally, on every element,
    ///      before any funds move — see the `batchMint` docs.
    error BatchMint__RewardTokenIsPaymentToken(address token);
    /// @dev Reverted when `rewardTokens` and `minRewards` have different lengths.
    error BatchMint__ArrayLengthMismatch(uint256 tokensLength, uint256 minsLength);
    /// @dev Reverted when `batchMint` is called while `tokenMinter` is unset.
    error BatchMint__MinterNotConfigured();
    /// @dev Reverted when `batchMint` is called while `dispatcherIndex` is unset
    ///      (`0`) or the pinned index resolves to a zero dispatcher.
    error BatchMint__DispatcherNotConfigured();
    /// @dev Reverted when `rescueERC20` is given a zero destination.
    error Rescue__ZeroRecipient();
    /// @dev Reverted when the deliverable reward for `token` is below the
    ///      caller's `minReward` floor for that token (front-run / pot drained
    ///      / batch does not qualify). Checked against the PRE-LOOP snapshot,
    ///      before any funds are pulled.
    error BatchMint__RewardBelowMinimum(address token, uint256 minReward, uint256 actualReward);

    event NudgeSizeChanged(uint256 newSize);
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

    /// @notice Owner-only recovery of an arbitrary ERC20.
    /// @dev    **This is NOT a reliable escape hatch.** Under the
    ///         caller-selected nudge model, every ERC20 balance this contract
    ///         holds (except the dispatcher's payment token) is claimable in
    ///         full by the next caller who clears the `nudgeSize` gate and
    ///         lists that token. `rescueERC20` therefore competes with every
    ///         watching bot in the mempool and is a **race the owner will
    ///         usually lose**. It is retained for two cases where it still
    ///         works: while `batchMint` is paused (no caller can claim
    ///         anything), and for tokens no batch has bothered to claim.
    ///         Treat "pause first, then rescue" as the only dependable
    ///         sequence.
    ///
    ///         Owner-trusted (the owner can already zero `nudgeSize` and stop
    ///         all payouts), so no token restriction is needed; an explicit
    ///         `amount` is preferred over a full-balance sweep so it composes
    ///         with the nudge pot. Stays callable while paused (mirrors
    ///         `NFTStaker.emergencyWithdraw`).
    function rescueERC20(IERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert Rescue__ZeroRecipient();
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    /// @notice Mint `count` NFT units of the owner-pinned `dispatcherIndex`
    ///         to `recipient`, pulling `paymentAmount` of the dispatcher's
    ///         prime token from `msg.sender` upfront and refunding any surplus.
    ///         When `count >= nudgeSize`, also pays `recipient` this contract's
    ///         entire pre-loop balance of every ERC20 listed in `rewardTokens`.
    ///
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
    ///         **The derived payment token may never appear in
    ///         `rewardTokens`.** That guard runs on every element of the array,
    ///         inside the snapshot pass, before any funds move — and
    ///         unconditionally, including on calls that do not qualify, so a
    ///         cheap sub-threshold call cannot be used to probe payment-token
    ///         balances. It is the only thing standing between a caller and
    ///         the payment-token balance held mid-transaction, and it prevents
    ///         two distinct failures: claiming accumulated sub-threshold
    ///         payment-token dust as "reward", and perturbing the
    ///         snapshot/refund accounting (both the upfront pull and the final
    ///         dust sweep operate on the payment token).
    ///
    ///         **Reward balances are SNAPSHOTTED BEFORE the mint loop and paid
    ///         AFTER it.** See the inline comments at both sites; this is the
    ///         "donate forward" mechanic and it is load-bearing.
    ///
    ///         **Reentrancy:** `rewardTokens` are caller-supplied addresses
    ///         this contract calls twice (`balanceOf`, then `transfer`), so a
    ///         malicious "token" can execute arbitrary code inside this
    ///         function, including reentering it. `nonReentrant` removes the
    ///         need to reason about the interleaving at all.
    ///
    ///         **Fee-on-transfer / rebasing tokens:** `minRewards` is a floor
    ///         on the contract's pre-transfer balance, not on the amount
    ///         `recipient` receives. For fee-on-transfer or rebasing tokens the
    ///         delivered amount will be lower. Supplying such a token is at the
    ///         caller's discretion.
    ///
    ///         **Array hygiene is the caller's responsibility:** supply your
    ///         own arrays at your own risk; a safe UI is provided. Only length
    ///         equality and the payment-token exclusion are validated.
    ///         Duplicate entries both snapshot the same balance and the second
    ///         transfer fails closed; a non-ERC20 address reverts on
    ///         `balanceOf`; absurdly long arrays are bounded only by the block
    ///         gas limit and are paid for by the caller. There is deliberately
    ///         no dedupe pass — it would be O(n^2) gas charged to every honest
    ///         caller to protect one careless one.
    ///
    /// @param  count            Number of mints (>0).
    /// @param  recipient        ERC1155 recipient (non-zero). Also the
    ///                          recipient of every reward transfer.
    /// @param  paymentAmount    Total payment-token to pull upfront.
    ///                          Must cover the dispatcher's cumulative
    ///                          cost across `count` iterations or an
    ///                          inner mint reverts. Surplus >=
    ///                          `DUST_THRESHOLD` is refunded.
    /// @param  rewardTokens     ERC20s the caller wants to be paid in. Empty
    ///                          is legal and means "no reward wanted" — a plain
    ///                          mint loop. Must not contain the derived payment
    ///                          token.
    /// @param  minRewards       Per-token slippage floor, parallel to
    ///                          `rewardTokens` (equal length required). If this
    ///                          contract's pre-loop balance of `rewardTokens[i]`
    ///                          is `< minRewards[i]` the WHOLE batch reverts
    ///                          `BatchMint__RewardBelowMinimum` before anything
    ///                          is pulled or minted, so the caller never pays
    ///                          mint costs for a pot that was front-run out from
    ///                          under them. `0` = no floor. NOTE: this does NOT
    ///                          stop a front-runner from winning the pot —
    ///                          whoever qualifies first still takes the entire
    ///                          balance-based payout; the floor only stops the
    ///                          loser from minting for less than they declared.
    /// @return totalPaid        Caller's net spend (`paymentAmount`
    ///                          minus any refunded surplus).
    function batchMint(
        uint256 count,
        address recipient,
        uint256 paymentAmount,
        address[] calldata rewardTokens,
        uint256[] calldata minRewards
    ) external whenNotPaused nonReentrant returns (uint256 totalPaid) {
        // --- 1. Validate the caller's inputs. ---
        if (count == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();
        if (rewardTokens.length != minRewards.length) {
            revert BatchMint__ArrayLengthMismatch(rewardTokens.length, minRewards.length);
        }

        // --- 2. Resolve the owner-pinned minter/dispatcher and DERIVE the
        //        payment asset from it. ---
        ITokenMinterV2 nftMinter = tokenMinter;
        if (address(nftMinter) == address(0)) {
            revert BatchMint__MinterNotConfigured();
        }

        uint256 _dispatcherIndex = dispatcherIndex;
        if (_dispatcherIndex == 0) revert BatchMint__DispatcherNotConfigured();

        IERC20 paymentToken;
        {
            (address dispatcher,,,) = INFTMinterV2(address(nftMinter)).configs(_dispatcherIndex);
            if (dispatcher == address(0)) revert BatchMint__DispatcherNotConfigured();
            paymentToken = IERC20(ITokenDispatcherV2(dispatcher).primeToken());
        }

        // --- 3 + 4. Eligibility, then the PRE-LOOP snapshot pass. ---
        //
        // DO NOT "SIMPLIFY" THIS BY MOVING THE BALANCE READ TO THE PAYOUT SITE.
        //
        // `_snapshotRewards` reads every listed reward balance HERE, before the
        // mint loop, and those figures are paid out AFTER it (step 9). The
        // dispatcher donates reward token into this contract on EVERY mint, so
        // the gap between this read and the payout is exactly this batch's own
        // donations. Reading before the loop means the batcher is paid only the
        // PRIOR accumulated pot; the donations generated by their own batch stay
        // behind to seed the next claimant. That "donate forward" mechanic is
        // the only thing preventing a caller from funding their own reward
        // inside a single transaction — a post-loop read would refund a batch's
        // own donations straight back to the batcher and collapse the incentive
        // to a no-op round-trip.
        //
        // Reading the balance immediately before the transfer looks obviously
        // cleaner and is silently wrong. Pinned by
        // `test_OwnDonationsDoNotRefundToBatcher`. See §4.2 of
        // `docs/multi-token-nudge.md`.
        //
        // The pass also runs the §4.1 payment-token exclusion on every element
        // UNCONDITIONALLY, and the per-token floor check — both ahead of the
        // pull and the mint loop, so nothing moves on a rejected call.
        bool qualifies;
        {
            uint256 _nudgeSize = nudgeSize;
            qualifies = _nudgeSize != 0 && count >= _nudgeSize;
        }
        uint256[] memory snapshot = _snapshotRewards(rewardTokens, minRewards, address(paymentToken), qualifies);

        // --- 5. Pull the caller's payment budget. ---
        paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);

        // --- 6. Approve the pinned minter for the loop. ---
        paymentToken.forceApprove(address(nftMinter), type(uint256).max);

        // --- 7. Mint loop. ---
        for (uint256 i; i < count; ++i) {
            nftMinter.mint(_dispatcherIndex, recipient);
        }

        // --- 8. Revoke the approval. ---
        paymentToken.forceApprove(address(nftMinter), 0);

        // --- 9. Payout pass. ---
        //
        // `snapshot` was captured BEFORE the mint loop above and is deliberately
        // NOT re-read here. Re-reading would hand the batcher the reward-token
        // donations its own mints just generated, turning the incentive into a
        // self-funded round-trip. The stale-looking figures are the whole point
        // — see the §4.2 note at the snapshot site above and in
        // `docs/multi-token-nudge.md`.
        _payRewards(recipient, rewardTokens, snapshot);

        // --- 10. Dust sweep of residual payment token back to msg.sender. ---
        uint256 remaining = paymentToken.balanceOf(address(this));
        if (remaining / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, remaining);
            totalPaid = paymentAmount > remaining ? paymentAmount - remaining : 0;
        } else {
            totalPaid = paymentAmount;
        }
    }

    /// @dev Step 4 of the normative execution order: the PRE-LOOP snapshot pass.
    ///
    ///      **These balances are read BEFORE the mint loop and paid out after
    ///      it (§4.2).** The dispatcher donates reward token into this contract
    ///      on every mint, so a batcher must be paid only the PRIOR accumulated
    ///      pot — their own batch's donations stay behind to seed the next
    ///      claimant. Moving this read next to the transfer looks cleaner and
    ///      silently collapses the incentive into a self-funded round-trip.
    ///      `test_OwnDonationsDoNotRefundToBatcher` exists to catch exactly
    ///      that refactor.
    ///
    ///      Three things happen per element, in this order:
    ///      1. §4.1 payment-token exclusion — UNCONDITIONAL. It runs even when
    ///         `qualifies` is false, so a cheap sub-threshold call can never be
    ///         used to probe this contract's payment-token balance, and it runs
    ///         before any funds move.
    ///      2. The balance read, but only when the batch qualifies; otherwise
    ///         the entry is pinned to `0`.
    ///      3. The per-token floor. Failing here — ahead of the payment pull
    ///         and the mint loop — is a pure gas improvement; the atomic
    ///         rollback guarantee is identical either way.
    ///
    ///      Duplicate entries are NOT deduped (§4.5): both snapshot the same
    ///      balance, the first transfer drains it and the second fails closed,
    ///      harming only the careless caller. A dedupe pass would be O(n^2) gas
    ///      charged to every honest caller.
    function _snapshotRewards(
        address[] calldata rewardTokens,
        uint256[] calldata minRewards,
        address paymentToken,
        bool qualifies
    ) private view returns (uint256[] memory snapshot) {
        uint256 tokenCount = rewardTokens.length;
        snapshot = new uint256[](tokenCount);
        for (uint256 i; i < tokenCount; ++i) {
            address rewardToken = rewardTokens[i];
            if (rewardToken == paymentToken) {
                revert BatchMint__RewardTokenIsPaymentToken(rewardToken);
            }
            uint256 available = qualifies ? IERC20(rewardToken).balanceOf(address(this)) : 0;
            uint256 minReward = minRewards[i];
            if (available < minReward) {
                revert BatchMint__RewardBelowMinimum(rewardToken, minReward, available);
            }
            snapshot[i] = available;
        }
    }

    /// @dev Step 9 of the normative execution order: the payout pass.
    ///
    ///      **`snapshot` was captured BEFORE the mint loop (§4.2) and must NOT
    ///      be recomputed here.** Re-reading `balanceOf` at this point would
    ///      pay the batcher the donations their own mints just produced — the
    ///      "donate forward" mechanic is exactly the difference between those
    ///      two readings, and it is the only thing stopping a caller from
    ///      funding their own reward inside one transaction. See the matching
    ///      note on `_snapshotRewards` and §4.2 of
    ///      `docs/multi-token-nudge.md`.
    ///
    ///      A zero entry means either the batch did not qualify or the pot was
    ///      empty; both are silent no-ops with no transfer and no event.
    ///      `NudgePaid` is emitted once per token ACTUALLY transferred.
    function _payRewards(address recipient, address[] calldata rewardTokens, uint256[] memory snapshot) private {
        uint256 tokenCount = snapshot.length;
        for (uint256 i; i < tokenCount; ++i) {
            uint256 amount = snapshot[i];
            if (amount == 0) continue;
            address rewardToken = rewardTokens[i];
            IERC20(rewardToken).safeTransfer(recipient, amount);
            emit NudgePaid(recipient, rewardToken, amount);
        }
    }
}
