// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMintDebtRatio} from "../../src/interfaces/IMintDebtRatio.sol";

/// @notice Exposes a settable `ratio()` (uint8, default 50) mirroring
///         `BalancerPoolerMintDebtHook.ratio`.
contract MockMintDebtRatioHook is IMintDebtRatio {
    uint8 public ratio = 50;

    function setRatio(uint8 newRatio) external {
        ratio = newRatio;
    }
}
