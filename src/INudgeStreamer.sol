// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  INudgeStreamer
interface INudgeStreamer {
    ///@dev msg.sender is the donor to the batchMinter.
    ///
    ///     `amount` is a REQUEST, not a credit. The stream is credited with the
    ///     receipt measured across the pull, capped at `amount`:
    ///     `min(balanceAfter - balanceBefore, amount)`. A fee-on-transfer or
    ///     taxed token therefore credits less than `amount`, and a token that
    ///     pushes extra balance in during the pull credits exactly `amount`
    ///     with the surplus left uncredited. `rewardPerSecond` is derived from
    ///     the credited value, and `NudgeCollected.amount` reports it — so a
    ///     consumer summing that field sees the credited receipt, not the
    ///     requested amount. A non-zero `amount` that delivers nothing reverts.
    ///
    ///     The signature is unchanged and the credited amount is deliberately
    ///     NOT returned: donors `forceApprove` an exact amount and ignore
    ///     returndata, and sibling repos compile against vendored copies of
    ///     this interface.
    function collectNudge(
        address recipientBatchMinter,
        address token,
        uint amount
    ) external;

    ///@dev msg.sender is a batchMinter
    function pullPendingStream(address token) external;

    function pendingStream(
        address batchMinter,
        address token
    ) external view returns (uint256);

    function registerStream(
        address batchMinter,
        address token,
        uint duration
    ) external;
}
