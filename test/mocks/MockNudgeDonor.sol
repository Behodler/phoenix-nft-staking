// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INudgeStreamer} from "../../src/NudgeStreamer.sol";

/// @notice Minimal donor double standing in for the real (unchanged) donor
///         contracts (`NudgeRatchet`, `StableYieldAccumulator`, etc.), which
///         live in sibling repos. It holds tokens and, on `donate`, approves the
///         streamer and calls `collectNudge` — mirroring how a real donor
///         replaces its old `ERC20.transfer(batchMinter, amount)`.
contract MockNudgeDonor {
    function donate(address streamer, address batchMinter, address token, uint256 amount) external {
        IERC20(token).approve(streamer, amount);
        INudgeStreamer(streamer).collectNudge(batchMinter, token, amount);
    }
}
