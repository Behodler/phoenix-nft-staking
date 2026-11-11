// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 18dp phUSD stand-in with FlaxToken's ALLOWANCE-BASED burn: `burn(holder, amount)`
///         spends `msg.sender`'s allowance over `holder` (transferFrom-style) and then burns.
///         A contract burning its own balance therefore needs a self-allowance first — a
///         missing self-approve reverts here exactly as it would on mainnet.
contract MockBurnablePhUSD is ERC20 {
    constructor() ERC20("Phoenix USD", "phUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address holder, uint256 amount) external {
        _spendAllowance(holder, msg.sender, amount);
        _burn(holder, amount);
    }
}
