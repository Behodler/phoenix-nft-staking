// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  INudgeStreamer
interface INudgeStreamer {
    ///@dev msg.sender is the donor to the batchMinter
    function pullPendingStream(
        address recipientBatchMinter,
        address token,
        uint amount
    ) external;

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
