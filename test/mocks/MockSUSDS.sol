// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Minimal sUSDS stand-in: an ERC4626-shaped share vault over a USDS mock, exposing
///         only what `BatchNFTMinterNudgeDiscount` and its tests touch (`asset`, `deposit`,
///         `redeem`, `totalAssets`, `convertToShares`, `convertToAssets`).
/// @dev    The story specified OZ `ERC4626`, but the vendored OZ ERC4626 is pinned to
///         `pragma ^0.8.24` and this repo compiles on solc 0.8.20 (via_ir off, no toolchain
///         change allowed), so it cannot be imported. Share maths mirror OZ's (virtual
///         offset 0: `shares = assets * (supply + 1) / (totalAssets + 1)`, floor). Yield is
///         simulated by transferring USDS straight into the vault, which raises the price.
contract MockSUSDS is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 private immutable _asset;

    constructor(IERC20 usds_) ERC20("Savings USDS", "sUSDS") {
        _asset = usds_;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function totalAssets() public view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 1, totalAssets() + 1);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, totalSupply() + 1);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        assets = convertToAssets(shares);
        _burn(owner, shares);
        _asset.safeTransfer(receiver, assets);
    }
}
