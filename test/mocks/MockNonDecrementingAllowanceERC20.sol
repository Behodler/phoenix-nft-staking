// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 whose `transferFrom` does **NOT** decrement the spender's
///         allowance. It still requires a sufficient allowance to be standing,
///         so it is not a free-for-all — it simply never consumes it.
///
/// @dev    This is the token-behaviour witness for
///         `BatchNFTMinterMultiToken`'s absolute-approval rule. `batchMint`
///         re-asserts `forceApprove(minter, price)` as an ABSOLUTE target on
///         every iteration and tracks the caller's spend in a local `budget`
///         variable, so:
///
///           - for a well-behaved token that decrements on `transferFrom`, each
///             write is idempotent;
///           - for one that does NOT decrement (this mock), each write is
///             corrective, and the final `forceApprove(minter, 0)` still zeroes
///             the standing allowance the last mint left behind.
///
///         Correctness therefore does not depend on the token's
///         allowance-decrement behaviour at all. A design that read
///         `allowance()` back to derive the refund — instead of tracking
///         `budget` locally — would mis-measure the spend against this token,
///         which is precisely why that design is forbidden.
///
///         Real-world instances of this class exist (tokens that special-case
///         `type(uint256).max` as an infinite allowance are the common form;
///         this mock generalises it to every amount so the property is pinned
///         unconditionally).
contract MockNonDecrementingAllowanceERC20 is ERC20 {
    error MockNonDecrementingAllowanceERC20__InsufficientAllowance(uint256 allowance, uint256 needed);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Deliberately omits `_spendAllowance`: the allowance is CHECKED but
    ///      never consumed.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 current = allowance(from, msg.sender);
        if (current < value) {
            revert MockNonDecrementingAllowanceERC20__InsufficientAllowance(current, value);
        }
        _transfer(from, to, value);
        return true;
    }
}
