// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBalancerPoolerMintDebtHook} from "yield-claim-nft/interfaces/IBalancerPoolerMintDebtHook.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test double for the dispatcher hook. `pull()` mints
///         `pendingMint` of the configured phUSD-like token to `recipient`,
///         then resets `pendingMint` to zero. Set `revertOnPull = true` to
///         simulate a broken hook for emergency-withdraw coverage.
contract MockBalancerPoolerMintDebtHook is IBalancerPoolerMintDebtHook {
    MockERC20 public immutable rewardToken;
    address public recipient;
    uint256 public pendingMint;
    bool public revertOnPull;

    constructor(MockERC20 _rewardToken, address _recipient) {
        rewardToken = _rewardToken;
        recipient = _recipient;
    }

    function setRecipient(address _recipient) external {
        recipient = _recipient;
    }

    function setPendingMint(uint256 amount) external {
        pendingMint = amount;
    }

    function setRevertOnPull(bool flag) external {
        revertOnPull = flag;
    }

    function mintDebt() external view returns (uint256) {
        return pendingMint;
    }

    function pull() external {
        require(!revertOnPull, "MockHook: pull reverted");
        uint256 amount = pendingMint;
        if (amount > 0) {
            pendingMint = 0;
            rewardToken.mint(recipient, amount);
        }
    }
}
