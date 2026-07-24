// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INudgeStreamer} from "./INudgeStreamer.sol";

/// @dev Minimal local view of the multi-token BatchMinter's nudge whitelist.
///      `registerStream` calls `isNudgeToken` on the target to enforce, in one
///      check, both "the token is on that batchMinter's whitelist" and "the
///      target is actually a MultiToken batchMinter" (a non-multitoken address
///      does not implement this and the call reverts).
interface IMultiTokenNudgeWhitelist {
    function isNudgeToken(address token) external view returns (bool);
}

/// @title  NudgeStreamer
/// @notice Buffers bursty donations per `(batchMinter, token)` and streams them
///         linearly to zero over a configured `duration`, so that whoever calls
///         `batchMint` right after a burst can no longer capture a
///         disproportionate share of the reward pot.
///
///         The linear-depletion math is ported from phlimbo's `PhlimboV2`
///         (`collectReward`/`_updatePool`), dropping the per-share accumulator —
///         a stream here is a flat per-`(batchMinter, token)` buffer, not a
///         pool of shares. The load-bearing invariant carried over from V2 is
///         **recompute-`rewardPerSecond`-on-deposit-only**: the rate is
///         recomputed solely in `collectNudge` (a deposit) and `registerStream`,
///         and NEVER on a flush/settle (`pullPendingStream`) or a view read.
///         V1's bug was resetting the streaming window on every touch; doing so
///         here would stretch depletion indefinitely.
///
///         Two flows, with distinct `msg.sender` semantics:
///         - `collectNudge(recipientBatchMinter, token, amount)` — a DONOR
///           (`msg.sender`) replaces its old `transfer(batchMinter, amount)`:
///           the streamer settles any accrued stream to the recipient, pulls
///           `amount` into the buffer, and recomputes the rate.
///         - `pullPendingStream(token)` — a BATCHMINTER (`msg.sender`, which is
///           also the implicit recipient) flushes its own accrued stream just
///           before it snapshots its balances. No rate recompute.
///
/// @dev    `PRECISION = 1e18` is an internal fixed-point multiplier, NOT a
///         decimal normalization. It cancels out
///         (`rewardPerSecond = buffer * 1e18 / duration`, then
///         `accrued = rewardPerSecond * elapsed / 1e18 = buffer * elapsed / duration`)
///         so every buffer value and transfer is in the token's NATIVE units;
///         6-dp (USDC) and 18-dp tokens both work unchanged. The scaling exists
///         only to stop `buffer / duration` truncating to zero for small-decimal
///         tokens over long windows. Integer division floors settled amounts;
///         leftover dust stays in the buffer and streams out later — dust always
///         accrues in the protocol's favour.
contract NudgeStreamer is INudgeStreamer, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Internal fixed-point multiplier for the per-second rate. See the
    ///         contract-level note: this is NOT decimal normalization.
    uint256 public constant PRECISION = 1e18;

    /// @notice One buffer per `(batchMinter, token)`.
    /// @param duration        Streaming window in seconds. `0` == unregistered.
    /// @param buffer          Undistributed tokens held for this pair (native units).
    /// @param rewardPerSecond Depletion rate, scaled by `PRECISION`.
    /// @param lastUpdate      Timestamp of the last settle.
    struct Stream {
        uint256 duration;
        uint256 buffer;
        uint256 rewardPerSecond;
        uint256 lastUpdate;
    }

    /// @notice `batchMinter => token => Stream`.
    mapping(address => mapping(address => Stream)) public streams;

    error NudgeStreamer__NotRegistered();
    error NudgeStreamer__ZeroDuration();
    error NudgeStreamer__ZeroAmount();
    error NudgeStreamer__NotWhitelisted(address batchMinter, address token);

    /// @notice Emitted when a stream is (re-)registered for a `(batchMinter, token)`.
    event StreamRegistered(
        address indexed batchMinter,
        address indexed token,
        uint256 duration,
        uint256 rewardPerSecond
    );

    /// @notice Emitted whenever accrued stream is settled and transferred to the batchMinter.
    event Streamed(address indexed batchMinter, address indexed token, uint256 amount);

    /// @notice Emitted when a donor tops up a stream's buffer.
    event NudgeCollected(
        address indexed batchMinter,
        address indexed token,
        address indexed donor,
        uint256 amount,
        uint256 rewardPerSecond
    );

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Register (or re-register) the stream for `(batchMinter, token)`.
    /// @dev    `onlyOwner`. Requires `duration > 0` and that `token` is on
    ///         `batchMinter`'s nudge whitelist — the `isNudgeToken` call also
    ///         reverts for non-multitoken targets, which is the structural
    ///         "only MultiToken batchMinter can be registered" guard. Any
    ///         pre-existing accrual is settled at the OLD rate before the window
    ///         is reset, mirroring phlimbo's `setDepletionDuration`.
    function registerStream(address batchMinter, address token, uint256 duration) external override onlyOwner {
        if (duration == 0) revert NudgeStreamer__ZeroDuration();
        if (!IMultiTokenNudgeWhitelist(batchMinter).isNudgeToken(token)) {
            revert NudgeStreamer__NotWhitelisted(batchMinter, token);
        }

        Stream storage s = streams[batchMinter][token];

        // Settle any accrued stream (re-registration) at the OLD rate first.
        _settle(s, batchMinter, token);

        s.duration = duration;
        // Recompute the rate over the FULL new window from now. This is one of
        // the only two recompute sites (the other is `collectNudge`).
        s.rewardPerSecond = (s.buffer * PRECISION) / duration;
        s.lastUpdate = block.timestamp;

        emit StreamRegistered(batchMinter, token, duration, s.rewardPerSecond);
    }

    /// @notice Donor-facing deposit (`msg.sender` = donor). Settles the accrued
    ///         stream to `recipientBatchMinter` at the OLD rate, pulls `amount`
    ///         from the donor into the buffer, then recomputes the rate.
    /// @dev    `nonReentrant`. Checks-effects-interactions: the settle updates
    ///         `buffer`/`lastUpdate` before its transfer, and the deposit pulls
    ///         funds before recomputing the rate. Mirrors phlimbo's
    ///         `collectReward` (which calls `_updatePool` before adding funds).
    function collectNudge(address recipientBatchMinter, address token, uint256 amount)
        external
        override
        nonReentrant
    {
        Stream storage s = streams[recipientBatchMinter][token];
        if (s.duration == 0) revert NudgeStreamer__NotRegistered();

        // Settle at the OLD rate before the new funds land.
        _settle(s, recipientBatchMinter, token);

        if (amount == 0) revert NudgeStreamer__ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        s.buffer += amount;

        // Canonical recompute site #1: reset the window over the full duration.
        s.rewardPerSecond = (s.buffer * PRECISION) / s.duration;

        emit NudgeCollected(recipientBatchMinter, token, msg.sender, amount, s.rewardPerSecond);
    }

    /// @notice BatchMinter-facing flush (`msg.sender` = batchMinter = recipient).
    ///         Settles the accrued stream and transfers it to `msg.sender`.
    ///         Unregistered streams are a cheap no-op so `batchMint` can loop
    ///         blindly over `getNudgeTokens()`.
    /// @dev    `nonReentrant`. NO rate recompute (mirrors phlimbo's
    ///         `_updatePool`, which never resets the window).
    function pullPendingStream(address token) external override nonReentrant {
        Stream storage s = streams[msg.sender][token];
        if (s.duration == 0) return; // not registered -> no-op

        _settle(s, msg.sender, token);
    }

    /// @notice Accrued-but-unsettled amount for `(batchMinter, token)`, capped by
    ///         the remaining buffer. UI reports this as already landed in the pot.
    /// @dev    View only — never recomputes the rate.
    function pendingStream(address batchMinter, address token) external view override returns (uint256) {
        Stream storage s = streams[batchMinter][token];
        return _accrued(s);
    }

    /// @dev Settle accrued stream for `s` and transfer it to `recipient`.
    ///      Effects (buffer/lastUpdate) precede the interaction (transfer).
    ///      NEVER recomputes `rewardPerSecond`.
    function _settle(Stream storage s, address recipient, address token) private {
        uint256 settled = _accrued(s);
        s.lastUpdate = block.timestamp;
        if (settled > 0) {
            s.buffer -= settled;
            IERC20(token).safeTransfer(recipient, settled);
            emit Streamed(recipient, token, settled);
        }
    }

    /// @dev `min(rewardPerSecond * elapsed / PRECISION, buffer)`. The buffer cap
    ///      guarantees the streamer can never transfer more than it holds, even
    ///      if `elapsed` is large.
    function _accrued(Stream storage s) private view returns (uint256) {
        uint256 elapsed = block.timestamp - s.lastUpdate;
        uint256 accrued = (s.rewardPerSecond * elapsed) / PRECISION;
        uint256 buffer = s.buffer;
        return accrued > buffer ? buffer : accrued;
    }
}
