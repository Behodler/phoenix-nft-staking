// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITokenDispatcherV2} from "yield-claim-nft/interfaces/ITokenDispatcherV2.sol";

/// @notice Minimal test double for a V2 token dispatcher. `BatchNFTMinter`
///         derives the payment asset by reading this dispatcher's
///         `primeToken()`. Wire `configs(index).dispatcher` (on
///         `MockITokenMinterV2`) to point at an instance of this mock so the
///         derived `paymentToken` equals the suite's funded `payToken`.
contract MockTokenDispatcherV2 is ITokenDispatcherV2 {
    address private _primeToken;

    constructor(address primeToken_) {
        _primeToken = primeToken_;
    }

    function setPrimeToken(address primeToken_) external {
        _primeToken = primeToken_;
    }

    function primeToken() external view override returns (address) {
        return _primeToken;
    }

    function name() external pure override returns (string memory) {
        return "MockDispatcher";
    }

    function image() external pure override returns (string memory) {
        return "";
    }

    function description() external pure override returns (string memory) {
        return "";
    }
}
