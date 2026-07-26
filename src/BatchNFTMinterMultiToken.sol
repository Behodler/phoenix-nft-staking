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
import {INudgeStreamer} from "./INudgeStreamer.sol";

/// @title BatchNFTMinterMultiToken
/// @notice Helper that loops `ITokenMinterV2.mint(...)` `count` times in a single
///         transaction, routing each minted unit to a caller-specified `recipient`.
///         The caller passes the aggregate `paymentAmount`; the helper pulls it
///         once upfront, then approves the minter for the EXACT price of each
///         individual mint immediately before making it, and revokes the
///         approval at the end. The minter is never granted an allowance
///         larger than the single mint it is about to charge for.
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
/// ### Whitelist-selected multi-token nudge (story-025)
///
/// The owner controls **eligibility** and the **set of reward assets**.
/// `nudgeSize` gates *who* qualifies (batch size >= threshold; `0` disables
/// the feature outright). An owner-managed whitelist
/// (`setNudgeTokenWhitelist`) declares *which* ERC20 balances held by this
/// contract are paid out; the caller supplies only a per-token `minRewards`
/// floor, ordered to match `getNudgeTokens()`. A qualifying caller receives
/// this contract's entire **pre-loop** balance of every whitelisted token.
///
/// This supersedes the story-022 caller-selected model, in which the caller
/// named arbitrary reward-token addresses per call. Vetting the token set at
/// admin time removes the weird-token attack surface that attacker-chosen
/// addresses opened — anything odd that lands here is simply left to
/// `rescueERC20`.
///
/// ### The payment token MAY be a nudge token (story-029)
///
/// A payment-token/nudge-token conflict is **permitted and safe**, not merely
/// tolerated. Earlier revisions claimed the conflict was made "structurally
/// impossible to exploit" by admin-time vetting; that claim was false, because
/// the owner can repoint `tokenMinter`/`dispatcherIndex` at any time and change
/// the derived payment token out from under an existing whitelist entry, and
/// because the refund was derived from `balanceOf` — a single number that
/// conflates three unrelated pools:
///
/// | pool | belongs to |
/// |---|---|
/// | `P`, the standing nudge pot | the next qualifying batch |
/// | `A - C`, unspent caller budget | `msg.sender` |
/// | `D`, this batch's own donations | the NEXT claimant (donate-forward) |
///
/// Handing `P + (A - C) + D` back as "residual" let a `count = 1`
/// non-qualifying batch paying one wei walk off with the whole pot
/// (yield-claim-nft submission `ycn19h1`). The remedy is not ordering — it is
/// the refund's SOURCE. `batchMint` now tracks the caller's spend in a local
/// `budget` and refunds from that, so `refund <= budget <= paymentAmount` holds
/// **by construction** for any `count`, any `nudgeSize` and any dispatcher
/// index. The pot can no longer leave through the refund at all, and the
/// payment token is paid out through the ordinary reward path like every other
/// whitelisted token.
///
/// `budget` is **measured across the pull, not quoted**: it is
/// `min(balance delta over the step-5 transfer, paymentAmount)`. This is what
/// makes the claim above unconditional rather than merely usual. Seeding it
/// with `paymentAmount` would trust a number the token never has to honour: a
/// fee-on-transfer payment token credits less than it is asked for, the refund
/// then overdraws by the fee, and the only balance able to cover the difference
/// is `P` — a non-qualifying batch shrinking the pot on every call. Measuring
/// charges the shortfall to the caller who incurred it. The `min` keeps the
/// measurement one-sided, so a token with a transfer callback cannot have a
/// third party's funds land inside the pull window and be refunded to the
/// batcher.
///
/// Two properties of the design, both intended:
///
/// - **Permissionless top-up.** Anyone can seed the batch incentive with any
///   whitelisted ERC20 simply by sending it here. No owner transaction is
///   involved in funding (only in curating the whitelist).
/// - **Winner-take-all capture.** Whoever qualifies first takes the entire
///   balance of every whitelisted token. Deliberate: unclaimed value should
///   not be stranded.
///
/// @dev **WARNING — whitelisted tokens sent to this contract may be claimed
///      by anyone who qualifies.** Any balance of a whitelisted token can be
///      swept in full by the next caller who clears the `nudgeSize` gate. Do
///      not use this address as custody. Non-whitelisted tokens are inert and
///      recoverable only via `rescueERC20`.
///
///      The pot is intended as a subsidy funded by yield derived from
///      protocol-owned capital, and in normal operation it is a fraction of
///      the cost of the `nudgeSize` mints required to qualify. **That is
///      funding policy, not a construction.** `qualifies` compares a count to
///      `nudgeSize` and nothing else — no expression in this contract relates
///      the pot to the cost — so a pot larger than one batch's cost is
///      claimable at a profit. That is accepted: because the pot is
///      yield-funded rather than drawn from principal or user deposits, an
///      over-large pot is an opportunity cost and marketing spend, not a
///      value leak. Do not add a value-aware cap to the payout on the
///      strength of this paragraph. If someone over-funds this contract
///      beyond the mint cost and a bot snipes it, that is still correct
///      behaviour; the error was in the sender.
///
/// The caller's UNSPENT BUDGET — what the pull actually credited, minus the
/// prices the mint loop actually charged — is refunded to `msg.sender` provided
/// it is at least `DUST_THRESHOLD` wei. For an ordinary ERC20 the credit is
/// `paymentAmount`; it is lower only for a token that skims its own transfers,
/// and the difference is borne by the caller rather than by the pot. This is a
/// budget refund, NOT a balance sweep: it is computed from a locally-tracked
/// counter, so dispatcher-side dust, a third-party donation and the standing
/// nudge pot are all invisible to it and none of them can leave this way. Sub-threshold surplus is intentionally left
/// behind to absorb JS-side rounding noise, where it becomes part of the pot for
/// the next qualifying claimant. A griefer who pre-deposits payment-token to
/// this contract simply donates to that claimant.
///
/// If `paymentAmount` falls short of the dispatcher's cumulative charge the
/// batch reverts `BatchMint__PaymentBudgetExhausted`, naming the mint index that
/// could not be funded, its price and the budget remaining at that point. It
/// does NOT silently draw the shortfall out of the contract's own balance.
///
/// Pausing is wired into the Phoenix global `Pauser` via the hybrid OZ
/// `Pausable` + `IPausable` pattern (see `NFTStaker`): a settable `pauser`
/// address may `pause()`/`unpause()`, and only `batchMint` is gated by
/// `whenNotPaused`. Admin setters and `rescueERC20` stay callable while paused.
///
/// `ReentrancyGuard` is retained even though reward tokens are now
/// owner-vetted rather than caller-chosen: the payout pass still executes
/// whatever code the whitelisted token addresses carry (`balanceOf`,
/// `transfer`), so a mistakenly whitelisted malicious/compromised token must
/// fail closed instead of interleaving. See the note on `batchMint`.
contract BatchNFTMinterMultiToken is Ownable, Pausable, ReentrancyGuard, IPausable {
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
    ///         disables the incentive entirely. Eligibility lever; the set of
    ///         reward assets is the owner-managed whitelist below.
    uint256 public nudgeSize;

    /// @notice Address authorised to pause/unpause via the global pauser.
    ///         Settable by the owner; `address(0)` disables pausing.
    address public pauser;

    /// @dev Ordered whitelist of nudge-reward tokens. Maintained as a manual
    ///      swap-remove set because OZ EnumerableSet requires solc ^0.8.24
    ///      while this repo targets 0.8.20 (same precedent as
    ///      `InPlaceNFTStakerMigrator`).
    address[] private _nudgeTokens;

    /// @dev 1-based index into `_nudgeTokens`; `0` == not whitelisted.
    mapping(address => uint256) private _nudgeTokenIndex;

    /// @notice Optional linear streamer that meters bursty donations into this
    ///         contract's nudge pot. `batchMint` flushes each whitelisted
    ///         token's accrued stream (via `pullPendingStream`) into the pot
    ///         right before it snapshots balances. `address(0)` disables the
    ///         integration, keeping the whole feature optional/backward-safe.
    address public nudgeStreamer;

    /// @dev Reverted when `count == 0`.
    error BatchMint__ZeroCount();
    /// @dev Reverted when `recipient == address(0)`.
    error BatchMint__ZeroRecipient();
    /// @dev Reverted when `setNudgeTokenWhitelist` tries to whitelist the
    ///      dispatcher's CURRENT derived payment token.
    ///
    ///      **DEFENCE IN DEPTH ONLY — the reason for this guard is gone.**
    ///      Story-029 made `paymentToken ∈ nudgeWhitelist` safe by construction
    ///      (see the contract header), and the runtime skip this used to pair
    ///      with has been removed. The check is retained deliberately, so the
    ///      admin-time surface and the runtime surface change in separate
    ///      releases rather than at once: an owner who wants the collision must
    ///      still arrive at it explicitly, by repointing
    ///      `tokenMinter`/`dispatcherIndex`, rather than stumbling into it from
    ///      a single whitelist call. It may be removed outright in a later
    ///      release with no change to `batchMint`'s guarantees.
    error BatchMint__RewardTokenIsPaymentToken(address token);
    /// @dev Reverted when `minRewards` does not cover the FULL whitelist
    ///      (`minRewards.length != getNudgeTokens().length`).
    error BatchMint__ArrayLengthMismatch(uint256 tokensLength, uint256 minsLength);
    /// @dev Reverted when `batchMint` is called while `tokenMinter` is unset.
    error BatchMint__MinterNotConfigured();
    /// @dev Reverted when `batchMint` is called while `dispatcherIndex` is unset
    ///      (`0`) or the pinned index resolves to a zero dispatcher.
    error BatchMint__DispatcherNotConfigured();
    /// @dev Reverted when `setNudgeTokenWhitelist` is given the zero address
    ///      to whitelist.
    error BatchMint__ZeroNudgeToken();
    /// @dev Reverted when whitelisting a token that is already whitelisted.
    ///      Loud by design (no silent no-op) — and the reason duplicate
    ///      reward entries are structurally impossible (audit-21 M-02).
    error BatchMint__NudgeTokenAlreadyWhitelisted(address token);
    /// @dev Reverted when unwhitelisting a token that is not whitelisted.
    ///      Loud by design (no silent no-op).
    error BatchMint__NudgeTokenNotWhitelisted(address token);
    /// @dev Reverted when `rescueERC20` is given a zero destination.
    error Rescue__ZeroRecipient();
    /// @dev Reverted when the deliverable reward for `token` is below the
    ///      caller's `minReward` floor for that token (front-run / pot drained
    ///      / batch does not qualify). Checked against the PRE-LOOP snapshot,
    ///      before any funds are pulled.
    error BatchMint__RewardBelowMinimum(address token, uint256 minReward, uint256 actualReward);
    /// @dev Reverted when the caller's remaining budget cannot cover the next
    ///      mint's price. Replaces the opaque ERC20 allowance/balance revert that
    ///      an under-funded batch used to produce.
    error BatchMint__PaymentBudgetExhausted(uint256 mintIndex, uint256 price, uint256 remaining);

    event NudgeSizeChanged(uint256 newSize);
    event NudgeTokenWhitelistChanged(address indexed token, bool allowed);
    event NudgePaid(address indexed recipient, address indexed token, uint256 amount);
    event TokenMinterSet(address indexed newMinter);
    event DispatcherIndexSet(uint256 indexed dispatcherIndex);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event PauserChanged(address indexed previousPauser, address indexed newPauser);
    event NudgeStreamerChanged(address indexed previousStreamer, address indexed newStreamer);

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

    /// @notice Ordered list of whitelisted nudge-reward tokens. The order of
    ///         `minRewards` in `batchMint` MUST match this order. Note:
    ///         unwhitelisting uses swap-and-pop, which REORDERS the list —
    ///         callers/UI must re-fetch before every `batchMint`.
    function getNudgeTokens() external view returns (address[] memory) {
        return _nudgeTokens;
    }

    /// @notice O(1) membership check against the nudge-token whitelist. Used by
    ///         `NudgeStreamer.registerStream` to confirm both that `token` is a
    ///         whitelisted reward asset and (by the mere existence of this
    ///         function) that this is a MultiToken batchMinter.
    function isNudgeToken(address token) external view returns (bool) {
        return _nudgeTokenIndex[token] != 0;
    }

    /// @notice Owner-gated update of the optional nudge streamer. Setting
    ///         `address(0)` disables the streamer flush in `batchMint`, leaving
    ///         all other behaviour unchanged. Stays callable while paused
    ///         (matches the other setters).
    function setNudgeStreamer(address newStreamer) external onlyOwner {
        emit NudgeStreamerChanged(nudgeStreamer, newStreamer);
        nudgeStreamer = newStreamer;
    }

    /// @notice Owner-gated add/remove of a nudge-reward token. Stays callable
    ///         while paused (matches the other setters).
    ///
    /// @dev    Adding (`allowed == true`) derives the payment token EXACTLY
    ///         as `batchMint` does (via `_resolvePaymentPath`) and rejects
    ///         the dispatcher's prime token. **This rejection is now defence in
    ///         depth, not a safety requirement** — see
    ///         `BatchMint__RewardTokenIsPaymentToken`. `batchMint` is safe with
    ///         the payment token on the whitelist (story-029), and it can end up
    ///         there anyway whenever the owner repoints
    ///         `tokenMinter`/`dispatcherIndex`; this check only stops a single
    ///         whitelist call from creating the collision by accident.
    ///         Re-adding an existing entry and removing an absent one both
    ///         revert loudly rather than silently no-op'ing.
    ///
    ///         Removal is swap-and-pop (O(1)): the LAST token moves into the
    ///         removed slot, so the `getNudgeTokens()` ordering changes.
    ///         Removal deliberately performs no payment-token derivation, so
    ///         the owner can always shrink the whitelist even while the
    ///         minter/dispatcher are unconfigured.
    function setNudgeTokenWhitelist(address token, bool allowed) external onlyOwner {
        if (allowed) {
            if (token == address(0)) revert BatchMint__ZeroNudgeToken();
            // DEFENCE IN DEPTH, NOT A SAFETY REQUIREMENT. `batchMint` no longer
            // depends on this being true: the refund is sourced from a tracked
            // budget, so the pot cannot leave through it even when the payment
            // token IS a nudge token. Removing this branch is safe; it is kept
            // for a release or two so the admin-time surface and the runtime
            // surface move separately.
            (,, IERC20 paymentToken) = _resolvePaymentPath();
            if (token == address(paymentToken)) {
                revert BatchMint__RewardTokenIsPaymentToken(token);
            }
            if (_nudgeTokenIndex[token] != 0) {
                revert BatchMint__NudgeTokenAlreadyWhitelisted(token);
            }
            _nudgeTokens.push(token);
            _nudgeTokenIndex[token] = _nudgeTokens.length;
        } else {
            uint256 oneBasedIndex = _nudgeTokenIndex[token];
            if (oneBasedIndex == 0) revert BatchMint__NudgeTokenNotWhitelisted(token);
            uint256 length = _nudgeTokens.length;
            if (oneBasedIndex != length) {
                address lastToken = _nudgeTokens[length - 1];
                _nudgeTokens[oneBasedIndex - 1] = lastToken;
                _nudgeTokenIndex[lastToken] = oneBasedIndex;
            }
            _nudgeTokens.pop();
            delete _nudgeTokenIndex[token];
        }
        emit NudgeTokenWhitelistChanged(token, allowed);
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
    /// @dev    Under the whitelist model this is the **dependable escape
    ///         hatch for anything not on the whitelist**: non-whitelisted
    ///         tokens sent here can never be claimed through `batchMint`, so
    ///         rescuing them is no longer a race against watching bots —
    ///         weird/unsupported tokens are explicitly left to this function.
    ///         Only balances of currently whitelisted tokens (and the
    ///         payment token's sweepable residue) compete with callers; for
    ///         those, "pause first (or unwhitelist), then rescue" remains the
    ///         dependable sequence.
    ///
    ///         Owner-trusted (the owner can already zero `nudgeSize`, edit
    ///         the whitelist, and stop all payouts), so no token restriction
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
    ///         When `count >= nudgeSize`, also pays `recipient` this contract's
    ///         entire pre-loop balance of every whitelisted nudge token
    ///         (see `getNudgeTokens`).
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
    ///         **The derived payment token MAY be a whitelisted nudge token.**
    ///         If the owner repoints `tokenMinter`/`dispatcherIndex` so that an
    ///         already-whitelisted token becomes the derived payment token, that
    ///         entry is snapshotted, floor-checked and paid out like any other:
    ///         the pot is read BEFORE the caller's budget arrives, so the
    ///         reading is uncontaminated, and the refund is computed from the
    ///         tracked budget rather than from `balanceOf`, so the pot cannot
    ///         leak into it. See the contract header for the full argument.
    ///
    ///         **Reward balances are SNAPSHOTTED BEFORE the mint loop and paid
    ///         AFTER it.** See the inline comments at both sites; this is the
    ///         "donate forward" mechanic and it is load-bearing.
    ///
    ///         **Reentrancy:** whitelisted tokens are addresses this contract
    ///         calls twice (`balanceOf`, then `transfer`). They are
    ///         owner-vetted rather than caller-chosen, but a mistakenly
    ///         whitelisted malicious token could still execute arbitrary code
    ///         inside this function; `nonReentrant` removes the need to
    ///         reason about the interleaving at all.
    ///
    ///         **Fee-on-transfer / rebasing tokens:** `minRewards` is a floor
    ///         on the contract's pre-transfer balance, not on the amount
    ///         `recipient` receives. For fee-on-transfer or rebasing tokens the
    ///         delivered amount will be lower. Whitelisting such a token is at
    ///         the owner's discretion.
    ///
    /// @param  count            Number of mints (>0).
    /// @param  recipient        ERC1155 recipient (non-zero). Also the
    ///                          recipient of every reward transfer.
    /// @param  paymentAmount    Total payment-token to pull upfront.
    ///                          Must cover the dispatcher's cumulative
    ///                          cost across `count` iterations, or the batch
    ///                          reverts `BatchMint__PaymentBudgetExhausted` at
    ///                          the first mint it cannot fund. Unspent budget
    ///                          >= `DUST_THRESHOLD` is refunded.
    /// @param  minRewards       Per-token slippage floor, parallel to
    ///                          `getNudgeTokens()` (equal length required —
    ///                          the FULL whitelist). Every entry's floor is
    ///                          live, including one currently equal to the
    ///                          derived payment token. Fetch the token list
    ///                          immediately before calling: unwhitelisting
    ///                          REORDERS it (swap-and-pop). If this
    ///                          contract's pre-loop balance of token `i`
    ///                          is `< minRewards[i]` the WHOLE batch reverts
    ///                          `BatchMint__RewardBelowMinimum` before anything
    ///                          is pulled or minted, so the caller never pays
    ///                          mint costs for a pot that was front-run out
    ///                          from under them. `0` = no floor. NOTE: this
    ///                          does NOT stop a front-runner from winning the
    ///                          pot — whoever qualifies first still takes the
    ///                          entire balance-based payout; the floor only
    ///                          stops the loser from minting for less than
    ///                          they declared.
    /// @return totalPaid        Caller's net spend (`paymentAmount`
    ///                          minus any refunded surplus).
    function batchMint(uint256 count, address recipient, uint256 paymentAmount, uint256[] calldata minRewards)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 totalPaid)
    {
        // --- 1. Validate the caller's inputs. ---
        if (count == 0) revert BatchMint__ZeroCount();
        if (recipient == address(0)) revert BatchMint__ZeroRecipient();
        if (_nudgeTokens.length != minRewards.length) {
            revert BatchMint__ArrayLengthMismatch(_nudgeTokens.length, minRewards.length);
        }

        // --- 2. Resolve the owner-pinned minter/dispatcher and DERIVE the
        //        payment asset from it. ---
        (ITokenMinterV2 nftMinter, uint256 _dispatcherIndex, IERC20 paymentToken) = _resolvePaymentPath();

        // --- 3 + 4. Eligibility, then the PRE-LOOP snapshot pass. ---
        //
        // DO NOT "SIMPLIFY" THIS BY MOVING THE BALANCE READ TO THE PAYOUT SITE.
        //
        // `_snapshotRewards` reads every whitelisted reward balance HERE,
        // before the mint loop, and those figures are paid out AFTER it
        // (step 10). The dispatcher donates reward token into this contract on
        // EVERY mint, so the gap between this read and the payout is exactly
        // this batch's own donations. Reading before the loop means the
        // batcher is paid only the PRIOR accumulated pot; the donations
        // generated by their own batch stay behind to seed the next claimant.
        // That "donate forward" mechanic is the only thing preventing a caller
        // from funding their own reward inside a single transaction — a
        // post-loop read would refund a batch's own donations straight back to
        // the batcher and collapse the incentive to a no-op round-trip.
        //
        // Reading the balance immediately before the transfer looks obviously
        // cleaner and is silently wrong. Pinned by
        // `test_OwnDonationsDoNotRefundToBatcher`. See §4.2 of
        // `docs/multi-token-nudge.md`.
        //
        // The pass also runs the per-token floor check, ahead of the pull and
        // the mint loop, so nothing moves on a rejected call.
        //
        // THE SNAPSHOT MUST STAY BEFORE THE PULL AT STEP 5. That ordering is
        // what makes the payment token's own reading the uncontaminated pot:
        // the caller's `paymentAmount` has not arrived yet, so it can never be
        // paid back to them as a reward. See the ORDER IS LOAD-BEARING note at
        // step 9 — this function now rests on TWO ordering constraints, not one.
        bool qualifies;
        {
            uint256 _nudgeSize = nudgeSize;
            qualifies = _nudgeSize != 0 && count >= _nudgeSize;
        }

        // --- 3.5. Flush accrued streams into the pot BEFORE the snapshot. ---
        //
        // If a NudgeStreamer is configured, settle each whitelisted token's
        // linearly-metered stream into this contract so the funds are counted
        // by the `_snapshotRewards` read below. Unregistered tokens are a cheap
        // no-op on the streamer side, so we can loop blindly over the whole
        // whitelist. This runs inside `batchMint`'s existing `nonReentrant`
        // guard.
        //
        // Block-scoped so `_nudgeStreamer` does not occupy a stack slot for the
        // rest of the function; `batchMint` is at the legacy code generator's
        // stack limit.
        {
            address _nudgeStreamer = nudgeStreamer;
            if (_nudgeStreamer != address(0)) {
                uint256 nudgeCount = _nudgeTokens.length;
                for (uint256 i; i < nudgeCount; ++i) {
                    INudgeStreamer(_nudgeStreamer).pullPendingStream(_nudgeTokens[i]);
                }
            }
        }

        uint256[] memory snapshot = _snapshotRewards(minRewards, qualifies);

        // --- 5. Pull the caller's payment budget, and MEASURE what arrived. ---
        //
        // `budget` is the caller's credit, and it is the ONLY thing the refund
        // in step 9 is allowed to draw on. It is therefore measured, not quoted:
        //
        //     budget = min(balanceAfterPull - balanceBeforePull, paymentAmount)
        //
        // THIS IS NOT THE FORBIDDEN `balanceOf` DERIVATION (see the warning at
        // the loop below). The difference is what the reading is OF. A single
        // absolute reading taken anywhere after step 5 sees `P + (A - C) + D` —
        // three pools, three owners, inseparable after the fact. A DIFFERENCE of
        // two readings taken immediately either side of ONE transfer sees only
        // that transfer's effect: `P` is in both readings and cancels, and `D`
        // has not happened yet. Bracketing this narrowly is the whole of the
        // distinction; widen the brackets to span the mint loop and the
        // measurement swallows `D` and the property is gone.
        //
        // - The LOWER side is why this is measured at all. `paymentAmount` is a
        //   quote, not a receipt: a fee-on-transfer payment token credits less
        //   than it is asked for. Trusting the quote made the refund overdraw by
        //   the fee, and the only balance available to cover the difference is
        //   `P`. That is a non-qualifying batch shrinking the pot, repeatably —
        //   and where the attacker controls the token's fee sink, extracting it.
        //   Pinned by `test_FeeOnTransferPaymentToken_potIsUntouchedWhenItHoldsThePot`.
        //
        // - The UPPER side — the `min` — is why the measurement is a ceiling and
        //   not a floor. A token with a transfer callback lets a third party push
        //   funds in DURING this call; `nonReentrant` blocks re-entering
        //   `batchMint`, not an inbound transfer landing mid-transfer. Un-capped,
        //   that donation would be credited to `msg.sender` and refunded to them
        //   — `D` re-routed to the batcher, which is `ycn19h1` through a narrower
        //   door. Capping at `paymentAmount` takes the TIGHTER of measured and
        //   quoted, so `budget <= paymentAmount` still holds by construction and
        //   `totalPaid = paymentAmount - refund` cannot underflow. Pinned by
        //   `test_DonationDuringPullCannotInflateBudget`.
        //
        // Block-scoped: `batchMint` is at the legacy code generator's stack
        // limit and only `budget` may survive.
        uint256 budget;
        {
            uint256 heldBeforePull = paymentToken.balanceOf(address(this));
            paymentToken.safeTransferFrom(msg.sender, address(this), paymentAmount);
            uint256 credited = paymentToken.balanceOf(address(this)) - heldBeforePull;
            budget = credited < paymentAmount ? credited : paymentAmount;
        }

        // --- 6 + 7. Mint loop, allowance held at the EXACT next mint price. ---
        //
        // DO NOT RE-DERIVE `budget` FROM `balanceOf`.
        //
        // `budget` is THIS CALLER'S money and nothing else. It is decremented by
        // the authoritative price the minter is about to charge, so it never
        // observes the pot, never observes this batch's own donations, and is
        // the ONLY source of the refund in step 9. Re-deriving it from
        // `balanceOf` — at this site or at the refund site — reintroduces
        // exactly the conflation this design removes, and with it the
        // `ycn19h1` pot drain: `balanceOf` after this loop is
        // `P + (A - C) + D`, three pools with three different owners, and no
        // reordering can separate them after the fact.
        //
        // The one permitted use of `balanceOf` for `budget` is the step-5 pull
        // bracket above, and ONLY there: a difference across a single transfer
        // measures that transfer, whereas any reading from here on measures the
        // conflation. In particular DO NOT bracket this loop the same way. The
        // mints themselves generate `D` (the dispatcher donates back per mint),
        // so a delta taken around an iteration reads `-price + D` and credits
        // the caller with the next claimant's money. The loop decrements by the
        // price the minter is about to charge, which is the caller's outflow and
        // nothing else.
        //
        // The price MUST be re-read every iteration. `NFTMinterV2._executeMint`
        // charges exactly `config.price` and THEN ramps it by
        // `growthBasisPoints`, so a pre-mint `configs()` read returns exactly
        // what this mint will charge and nothing else. Extrapolating the ramp
        // locally would make this contract's arithmetic a convention that has to
        // track the minter's; re-reading keeps it correct by construction.
        //
        // Every `forceApprove` below sets an ABSOLUTE target, never a delta.
        // For a well-behaved ERC20 that decrements allowance on `transferFrom`
        // the write is idempotent; for one that does NOT decrement it is
        // corrective. Correctness therefore does not depend on the token's
        // allowance-decrement behaviour at all — pinned by
        // `test_NonDecrementingAllowanceToken_refundUnaffected` and
        // `test_ApprovalIsAbsoluteNotDelta`.
        for (uint256 i; i < count; ++i) {
            (, uint256 price,,) = INFTMinterV2(address(nftMinter)).configs(_dispatcherIndex);
            if (price > budget) revert BatchMint__PaymentBudgetExhausted(i, price, budget);
            paymentToken.forceApprove(address(nftMinter), price);
            budget -= price;
            nftMinter.mint(_dispatcherIndex, recipient);
        }

        // --- 8. Revoke. Absolute and idempotent: zeroes any allowance a
        //        non-decrementing token left standing after the final mint. ---
        paymentToken.forceApprove(address(nftMinter), 0);

        // --- 9. Refund the caller's UNSPENT BUDGET. Not a balance sweep. ---
        //
        // ORDER IS LOAD-BEARING, IN TWO PLACES.
        //   1. The snapshot (step 4) must stay BEFORE the pull (step 5), so the
        //      caller's own money is never visible to the payout.
        //   2. The refund (here) must stay BEFORE the payout (step 10), so a
        //      payout can never be funded out of a refund that is owed, and
        //      vice versa.
        // Two ordering constraints hold this function up, not one.
        //
        // `refund <= paymentAmount` HOLDS BY CONSTRUCTION, because `budget`
        // starts at no more than `paymentAmount` (step 5 takes the tighter of
        // the credited and the quoted amount) and only ever decreases.
        //
        // The `available` cap is BELT-AND-BRACES, not a mechanism. Step 5 used
        // to trust `paymentAmount`, which made this cap the only thing standing
        // between a fee-on-transfer shortfall and the pot — and it was standing
        // in the wrong place, because capping at the balance still lets the
        // refund reach past the caller's credit and into `P`. Now that `budget`
        // is measured, the cap is non-binding on every path we can construct;
        // it is retained only so an unforeseen shortfall degrades into a smaller
        // refund rather than a revert. It can lower the refund, never raise it,
        // and is never its source.
        //
        // Solvency is likewise structural: the refund needs `credited - C` and
        // the balance holds `P + (credited - C) + D`, which is never smaller.
        {
            uint256 available = paymentToken.balanceOf(address(this));
            uint256 refund = budget > available ? available : budget;
            if (refund / DUST_THRESHOLD != 0) {
                paymentToken.safeTransfer(msg.sender, refund);
                totalPaid = paymentAmount - refund;
            } else {
                totalPaid = paymentAmount;
            }
        }

        // --- 10. Payout pass. ---
        //
        // `snapshot` was captured BEFORE the mint loop above and is deliberately
        // NOT re-read here. Re-reading would hand the batcher the reward-token
        // donations its own mints just generated, turning the incentive into a
        // self-funded round-trip. The stale-looking figures are the whole point
        // — see the §4.2 note at the snapshot site above and in
        // `docs/multi-token-nudge.md`.
        _payRewards(recipient, snapshot);
    }

    /// @dev Shared resolution of the owner-pinned minter/dispatcher and the
    ///      DERIVED payment token. Used by both `batchMint` (step 2) and
    ///      `setNudgeTokenWhitelist`'s add branch, so the latter's
    ///      defence-in-depth check is evaluated against exactly the token
    ///      `batchMint` would derive rather than against a second, drifting
    ///      derivation. That check is no longer load-bearing (see
    ///      `BatchMint__RewardTokenIsPaymentToken`); sharing the resolution is
    ///      simply the correct way to keep two readings of the same state in
    ///      agreement.
    function _resolvePaymentPath()
        private
        view
        returns (ITokenMinterV2 nftMinter, uint256 _dispatcherIndex, IERC20 paymentToken)
    {
        nftMinter = tokenMinter;
        if (address(nftMinter) == address(0)) {
            revert BatchMint__MinterNotConfigured();
        }

        _dispatcherIndex = dispatcherIndex;
        if (_dispatcherIndex == 0) revert BatchMint__DispatcherNotConfigured();

        (address dispatcher,,,) = INFTMinterV2(address(nftMinter)).configs(_dispatcherIndex);
        if (dispatcher == address(0)) revert BatchMint__DispatcherNotConfigured();
        paymentToken = IERC20(ITokenDispatcherV2(dispatcher).primeToken());
    }

    /// @dev Step 4 of the normative execution order: the PRE-LOOP snapshot
    ///      pass, iterating the owner-managed whitelist in storage order
    ///      (`minRewards[i]` binds to `_nudgeTokens[i]`).
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
    ///      Reading the whitelist from storage inside the loop is fine now:
    ///      the story-022 design kept reward tokens out of storage because
    ///      they were attacker-supplied per call; under the whitelist model
    ///      the addresses are owner-vetted state, and the storage reads are
    ///      the point (the caller cannot substitute their own list).
    ///
    ///      **NO ENTRY IS SKIPPED — including one equal to the derived payment
    ///      token (story-029).** The earlier revision `continue`d that entry and
    ///      justified it as keeping `batchMint` live "while the payment-token
    ///      balance stays out of the payout". The second half of that claim was
    ///      false: `ycn19h1` showed the balance left anyway, in full, through the
    ///      step-10 balance sweep, to a caller who had not qualified for
    ///      anything. The remedy was to fix the refund's source, not to keep
    ///      discarding a perfectly good reading — this pass runs BEFORE the
    ///      caller's budget is pulled, so the payment token's balance here is the
    ///      uncontaminated pot, exactly as clean as any other whitelisted
    ///      token's.
    ///
    ///      Two things happen per element, in this order:
    ///      1. The balance read, but only when the batch qualifies; otherwise
    ///         the entry is pinned to `0`.
    ///      2. The per-token floor. Failing here — ahead of the payment pull
    ///         and the mint loop — is a pure gas improvement; the atomic
    ///         rollback guarantee is identical either way.
    ///
    ///      Duplicate entries are structurally impossible (§4.5): the
    ///      whitelist is a set, and `setNudgeTokenWhitelist` reverts on
    ///      re-add. No dedupe pass is needed — by construction, not by scan.
    function _snapshotRewards(uint256[] calldata minRewards, bool qualifies)
        private
        view
        returns (uint256[] memory snapshot)
    {
        uint256 tokenCount = _nudgeTokens.length;
        snapshot = new uint256[](tokenCount);
        for (uint256 i; i < tokenCount; ++i) {
            address rewardToken = _nudgeTokens[i];
            uint256 available = qualifies ? IERC20(rewardToken).balanceOf(address(this)) : 0;
            uint256 minReward = minRewards[i];
            if (available < minReward) {
                revert BatchMint__RewardBelowMinimum(rewardToken, minReward, available);
            }
            snapshot[i] = available;
        }
    }

    /// @dev Step 10 of the normative execution order: the payout pass, walking
    ///      the same whitelist storage order as `_snapshotRewards`. It runs
    ///      AFTER the caller's unspent budget has been refunded (step 9), so the
    ///      two transfers can never be funded out of one another.
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
    ///      A zero entry means the batch did not qualify or the pot was empty;
    ///      both are silent no-ops with no transfer and no event. `NudgePaid`
    ///      is emitted once per token ACTUALLY transferred.
    function _payRewards(address recipient, uint256[] memory snapshot) private {
        uint256 tokenCount = snapshot.length;
        for (uint256 i; i < tokenCount; ++i) {
            uint256 amount = snapshot[i];
            if (amount == 0) continue;
            address rewardToken = _nudgeTokens[i];
            IERC20(rewardToken).safeTransfer(recipient, amount);
            emit NudgePaid(recipient, rewardToken, amount);
        }
    }
}
