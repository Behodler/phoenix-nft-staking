// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";

/// @notice Attacker-controlled no-op minter standing in for the MEV bot's
///         contract in the real nudge-drain exploit. `mint(...)` does no work
///         (no payment pull, no NFT issuance) and returns `true` for ~no gas,
///         so a caller can fake an arbitrarily large batch to clear the
///         `count >= nudgeSize` gate without paying for any real mints. This
///         is exactly the attack surface the minter-pinning fix removes by
///         dropping the caller-supplied `nftMinter` parameter.
contract MockNoopMinter is ITokenMinterV2 {
    function mint(uint256, address) external pure override returns (bool) {
        return true;
    }

    function mint(uint256, address, bytes calldata) external pure override returns (bool) {
        return true;
    }

    function getPrice(uint256) external pure override returns (uint256) {
        return 0;
    }

    function registerDispatcher(address, uint256, uint256) external pure override {}

    function setPrice(uint256, uint256) external pure override {}

    function setGrowthFactor(uint256, uint256) external pure override {}
}
