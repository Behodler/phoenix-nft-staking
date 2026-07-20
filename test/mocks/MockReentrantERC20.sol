// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious "reward token" that reenters `BatchNFTMinter.batchMint`
///         from inside its own `transfer`.
///
///         `rewardTokens` are caller-supplied addresses that `BatchNFTMinter`
///         calls twice (`balanceOf` during the snapshot pass, `transfer`
///         during the payout pass). The second of those is an arbitrary-code
///         hook the attacker controls, so the payout pass is a reentrancy
///         surface that the previous owner-configured single-token design did
///         not have. §4.3 of `docs/multi-token-nudge.md` mandates
///         `nonReentrant` on `batchMint`; this mock is what proves it is
///         wired.
///
///         The reentrant call is made with a raw `call` (rather than a typed
///         import of `BatchNFTMinter`) so the revert data bubbles verbatim —
///         the test can then assert the exact
///         `ReentrancyGuardReentrantCall` selector.
contract MockReentrantERC20 is ERC20 {
    address public target;
    bool public armed;
    uint256 public reentryAttempts;

    // Parameters replayed into the nested `batchMint` frame.
    uint256 private _count;
    address private _recipient;
    uint256 private _paymentAmount;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm a single reentry into `target_.batchMint(...)` on the next
    ///         `transfer`. One-shot: the flag is cleared before the nested
    ///         call so an unguarded contract would recurse exactly once
    ///         rather than until out-of-gas.
    function arm(address target_, uint256 count_, address recipient_, uint256 paymentAmount_) external {
        target = target_;
        _count = count_;
        _recipient = recipient_;
        _paymentAmount = paymentAmount_;
        armed = true;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (armed) {
            armed = false;
            reentryAttempts += 1;
            (bool ok, bytes memory ret) = target.call(
                abi.encodeWithSignature(
                    "batchMint(uint256,address,uint256,address[],uint256[])",
                    _count,
                    _recipient,
                    _paymentAmount,
                    new address[](0),
                    new uint256[](0)
                )
            );
            if (!ok) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        return super.transfer(to, value);
    }
}
