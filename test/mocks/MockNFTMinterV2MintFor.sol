// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockITokenMinterV2} from "./MockITokenMinterV2.sol";

/// @notice `MockITokenMinterV2` plus `NFTMinterV2`'s authorised free-mint path
///         (yield-claim-nft `src/NFTMinterV2.sol:206`). `mintFor`:
///           - requires the caller to be an authorised minter;
///           - mints 1 unit of `index` of the staked ERC1155 to `recipient`;
///           - takes NO payment, does NOT dispatch (no per-mint donation), and does NOT
///             touch the stored price;
///           - counts its calls in `mintForCallCount`.
///         Inherits rather than edits the shared mock, so existing suites are untouched.
contract MockNFTMinterV2MintFor is MockITokenMinterV2 {
    mapping(address => bool) public authorizedMinters;
    uint256 public mintForCallCount;

    error MockNFTMinterV2MintFor__NotAuthorized(address caller);

    function setAuthorizedMinter(address minter, bool authorized) external {
        authorizedMinters[minter] = authorized;
    }

    function mintFor(uint256 index, address recipient) external {
        if (!authorizedMinters[msg.sender]) revert MockNFTMinterV2MintFor__NotAuthorized(msg.sender);
        mintForCallCount += 1;
        stakedToken.mint(recipient, index, 1);
    }
}
