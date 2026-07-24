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
/// admin time (1) makes a payment-token/nudge-token conflict structurally
/// impossible to exploit, and (2) removes the weird-token attack surface that
/// attacker-chosen addresses opened — anything odd that lands here is simply
/// left to `rescueERC20`.
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
///      recoverable only via `rescueERC20`. The "honeypot" framing does not
///      apply, because the pot is by construction a fraction of the cost of
///      the `nudgeSize` mints required to qualify — every claim is
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
    ///      dispatcher's derived payment token. Admin-time guard; the runtime
    ///      counterpart is the skip in `_snapshotRewards` (see there).
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
    ///         the dispatcher's prime token — the admin-time half of the §4.1
    ///         payment-token exclusion. Re-adding an existing entry and
    ///         removing an absent one both revert loudly rather than
    ///         silently no-op'ing.
    ///
    ///         Removal is swap-and-pop (O(1)): the LAST token moves into the
    ///         removed slot, so the `getNudgeTokens()` ordering changes.
    ///         Removal deliberately performs no payment-token derivation, so
    ///         the owner can always shrink the whitelist even while the
    ///         minter/dispatcher are unconfigured.
    function setNudgeTokenWhitelist(address token, bool allowed) external onlyOwner {
        if (allowed) {
            if (token == address(0)) revert BatchMint__ZeroNudgeToken();
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
    ///         **The derived payment token can never be whitelisted** —
    ///         `setNudgeTokenWhitelist` rejects it at admin time. If the
    ///         owner later repoints `tokenMinter`/`dispatcherIndex` so that
    ///         an already-whitelisted token BECOMES the derived payment
    ///         token, the snapshot loop SKIPS that entry at runtime (no
    ///         snapshot, no payout, its `minRewards[i]` ignored) instead of
    ///         reverting — keeping `batchMint` live rather than bricked while
    ///         still keeping the payment-token balance out of the payout
    ///         (that balance follows the normal dust-sweep path).
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
    ///                          cost across `count` iterations or an
    ///                          inner mint reverts. Surplus >=
    ///                          `DUST_THRESHOLD` is refunded.
    /// @param  minRewards       Per-token slippage floor, parallel to
    ///                          `getNudgeTokens()` (equal length required —
    ///                          the FULL whitelist, including any entry
    ///                          currently equal to the derived payment token,
    ///                          whose floor is ignored). Fetch the token list
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
        // (step 9). The dispatcher donates reward token into this contract on
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
        // The pass also runs the §4.1 runtime payment-token SKIP on every
        // element, and the per-token floor check — both ahead of the pull and
        // the mint loop, so nothing moves on a rejected call.
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
        address _nudgeStreamer = nudgeStreamer;
        if (_nudgeStreamer != address(0)) {
            uint256 nudgeCount = _nudgeTokens.length;
            for (uint256 i; i < nudgeCount; ++i) {
                INudgeStreamer(_nudgeStreamer).pullPendingStream(_nudgeTokens[i]);
            }
        }

        uint256[] memory snapshot = _snapshotRewards(minRewards, address(paymentToken), qualifies);

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
        _payRewards(recipient, snapshot);

        // --- 10. Dust sweep of residual payment token back to msg.sender. ---
        uint256 remaining = paymentToken.balanceOf(address(this));
        if (remaining / DUST_THRESHOLD != 0) {
            paymentToken.safeTransfer(msg.sender, remaining);
            totalPaid = paymentAmount > remaining ? paymentAmount - remaining : 0;
        } else {
            totalPaid = paymentAmount;
        }
    }

    /// @dev Shared resolution of the owner-pinned minter/dispatcher and the
    ///      DERIVED payment token. Used by both `batchMint` (step 2) and
    ///      `setNudgeTokenWhitelist`'s add branch, so the admin-time
    ///      payment-token exclusion is checked against exactly the token
    ///      `batchMint` would derive — by construction, not by convention.
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
    ///      Three things happen per element, in this order:
    ///      1. §4.1 runtime payment-token SKIP: an entry equal to the derived
    ///         payment token is `continue`d — snapshot stays 0, its
    ///         `minRewards[i]` is IGNORED, no revert. The admin-time check in
    ///         `setNudgeTokenWhitelist` prevents this at write time, but the
    ///         owner can later repoint `tokenMinter`/`dispatcherIndex` and
    ///         change the derived payment token out from under an existing
    ///         entry; skipping keeps `batchMint` live instead of bricking it,
    ///         while the payment-token balance stays out of the payout.
    ///      2. The balance read, but only when the batch qualifies; otherwise
    ///         the entry is pinned to `0`.
    ///      3. The per-token floor. Failing here — ahead of the payment pull
    ///         and the mint loop — is a pure gas improvement; the atomic
    ///         rollback guarantee is identical either way.
    ///
    ///      Duplicate entries are structurally impossible (§4.5): the
    ///      whitelist is a set, and `setNudgeTokenWhitelist` reverts on
    ///      re-add. No dedupe pass is needed — by construction, not by scan.
    function _snapshotRewards(uint256[] calldata minRewards, address paymentToken, bool qualifies)
        private
        view
        returns (uint256[] memory snapshot)
    {
        uint256 tokenCount = _nudgeTokens.length;
        snapshot = new uint256[](tokenCount);
        for (uint256 i; i < tokenCount; ++i) {
            address rewardToken = _nudgeTokens[i];
            if (rewardToken == paymentToken) continue;
            uint256 available = qualifies ? IERC20(rewardToken).balanceOf(address(this)) : 0;
            uint256 minReward = minRewards[i];
            if (available < minReward) {
                revert BatchMint__RewardBelowMinimum(rewardToken, minReward, available);
            }
            snapshot[i] = available;
        }
    }

    /// @dev Step 9 of the normative execution order: the payout pass, walking
    ///      the same whitelist storage order as `_snapshotRewards`.
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
    ///      A zero entry means the batch did not qualify, the pot was empty,
    ///      or the entry was runtime-skipped as the current payment token;
    ///      all are silent no-ops with no transfer and no event. `NudgePaid`
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
