// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INFTSupply} from "../../src/INFTSupply.sol";

/// @notice Test double for the subset of `NFTMinterV2` that `NFTStaker`
///         reads. Exposes the `totalSupply(uint256)` getter (ERC1155Supply
///         surface) and a single mutable `configs` entry keyed by
///         dispatcherIndex. Setters are unrestricted so tests can freely
///         drive the math without mining NFTs or wiring a real dispatcher.
contract MockNFTMinter is INFTSupply {
    struct Config {
        address dispatcher;
        uint256 price;
        uint256 growthBasisPoints;
        bool disabled;
    }

    mapping(uint256 => uint256) private _totalSupply;
    mapping(uint256 => Config) private _configs;

    // ---- INFTSupply ----

    function totalSupply(uint256 id) external view override returns (uint256) {
        return _totalSupply[id];
    }

    function configs(uint256 index)
        external
        view
        override
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled)
    {
        Config memory c = _configs[index];
        return (c.dispatcher, c.price, c.growthBasisPoints, c.disabled);
    }

    // ---- Test helpers ----

    function setTotalSupply(uint256 id, uint256 supply) external {
        _totalSupply[id] = supply;
    }

    function setConfig(uint256 index, address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled)
        external
    {
        _configs[index] = Config({
            dispatcher: dispatcher,
            price: price,
            growthBasisPoints: growthBasisPoints,
            disabled: disabled
        });
    }
}
