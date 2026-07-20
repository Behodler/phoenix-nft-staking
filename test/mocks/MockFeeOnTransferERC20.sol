// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that skims a basis-points fee on every non-mint, non-burn
///         transfer. Used as the §4.4 witness: `BatchNFTMinter` checks
///         `minRewards[i]` against its own PRE-TRANSFER balance, not against
///         what `recipient` actually receives, so a fee-on-transfer reward
///         token delivers below the caller's declared floor without
///         reverting. That is documented behaviour, not a defect — this mock
///         exists so a future change that "fixes" it fails loudly.
contract MockFeeOnTransferERC20 is ERC20 {
    /// @dev Fee skimmed on each transfer, in basis points of the amount.
    uint256 public immutable feeBasisPoints;

    /// @dev Where the skimmed fee lands. A non-zero sink is used (rather than
    ///      a burn) so `_update` never recurses through the zero-address
    ///      mint/burn branch.
    address public constant FEE_SINK = address(0xFEE5);

    constructor(string memory name_, string memory symbol_, uint256 feeBasisPoints_) ERC20(name_, symbol_) {
        feeBasisPoints = feeBasisPoints_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBasisPoints == 0) {
            // Mint / burn / fee-free configuration: pass straight through.
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBasisPoints) / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) {
            super._update(from, FEE_SINK, fee);
        }
    }
}
