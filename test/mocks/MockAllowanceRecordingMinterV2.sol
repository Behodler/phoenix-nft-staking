// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenMinterV2} from "yield-claim-nft/interfaces/ITokenMinterV2.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC1155} from "./MockERC1155.sol";

/// @notice `MockITokenMinterV2` plus one extra faculty: it RECORDS the
///         allowance `msg.sender` (the batch minter) had granted it at the
///         instant each `mint` was entered, before any `transferFrom` consumed
///         it.
///
/// @dev    This is a DEDICATED recording mock rather than a flag on the shared
///         `MockITokenMinterV2` on purpose: the shared mock drives 500+ existing
///         tests and the gas snapshot, and an extra `SLOAD`/`SSTORE` per mint
///         there would contaminate the story-029 gas delta measurement with a
///         test-harness artefact. Nothing here is on any production path.
///
///         Price ramp mirrors `NFTMinterV2._executeMint` exactly:
///         `price = price + (price * growthBasisPoints) / 10000`, applied AFTER
///         the charge, so a pre-mint `configs()` read returns exactly what that
///         mint will charge.
contract MockAllowanceRecordingMinterV2 is ITokenMinterV2 {
    using SafeERC20 for IERC20;

    struct Config {
        uint256 price;
        uint256 growthBasisPoints;
    }

    mapping(uint256 => Config) private _configs;
    mapping(uint256 => address) private _primeToken;
    mapping(uint256 => address) private _dispatcher;
    MockERC1155 public stakedToken;

    uint256 public mintCallCount;

    /// @dev `allowance(batchMinter, this)` observed at the head of each `mint`,
    ///      in call order.
    uint256[] private _observedAllowances;
    /// @dev The price each recorded mint actually charged, in call order.
    uint256[] private _chargedPrices;

    function mint(uint256 index, address recipient) external override returns (bool) {
        mintCallCount += 1;
        Config storage c = _configs[index];
        uint256 price = c.price;

        // The measurement: what the batch minter had approved us for, BEFORE
        // this mint's `transferFrom` touches it.
        _observedAllowances.push(IERC20(_primeToken[index]).allowance(msg.sender, address(this)));
        _chargedPrices.push(price);

        IERC20(_primeToken[index]).safeTransferFrom(msg.sender, address(this), price);
        stakedToken.mint(recipient, index, 1);
        // Matches `NFTMinterV2._executeMint`'s ramp, term for term.
        c.price = price + (price * c.growthBasisPoints) / 10000;
        return true;
    }

    function getPrice(uint256 index) external view override returns (uint256) {
        return _configs[index].price;
    }

    function configs(uint256 index)
        external
        view
        returns (address dispatcher, uint256 price, uint256 growthBasisPoints, bool disabled)
    {
        Config storage c = _configs[index];
        return (_dispatcher[index], c.price, c.growthBasisPoints, false);
    }

    // ---- unused ITokenMinterV2 surface ----

    function mint(uint256, address, bytes calldata) external pure override returns (bool) {
        revert("MockAllowanceRecordingMinterV2: extraData mint not supported");
    }

    function registerDispatcher(address, uint256, uint256) external pure override {
        revert("MockAllowanceRecordingMinterV2: not implemented");
    }

    function setPrice(uint256 index, uint256 newPrice) external override {
        _configs[index].price = newPrice;
    }

    function setGrowthFactor(uint256 index, uint256 newGrowthBasisPoints) external override {
        _configs[index].growthBasisPoints = newGrowthBasisPoints;
    }

    // ---- test helpers ----

    function setConfig(uint256 index, uint256 price, uint256 growthBasisPoints) external {
        _configs[index] = Config({price: price, growthBasisPoints: growthBasisPoints});
    }

    function setPrimeToken(uint256 index, address token) external {
        _primeToken[index] = token;
    }

    function setDispatcher(uint256 index, address dispatcher) external {
        _dispatcher[index] = dispatcher;
    }

    function setStakedToken(MockERC1155 token) external {
        stakedToken = token;
    }

    function observedAllowanceCount() external view returns (uint256) {
        return _observedAllowances.length;
    }

    function observedAllowanceAt(uint256 i) external view returns (uint256) {
        return _observedAllowances[i];
    }

    function chargedPriceAt(uint256 i) external view returns (uint256) {
        return _chargedPrices[i];
    }
}
