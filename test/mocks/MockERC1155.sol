// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice Minimal ERC1155 implementation for testing.
///
/// We deliberately do NOT inherit OpenZeppelin's `ERC1155` here because that
/// implementation uses solc ^0.8.24 features and the rest of this submodule
/// (and its sibling modules) targets 0.8.20. This mock implements only the
/// surface needed for `NFTStaker` tests: balances, single transfer with
/// receiver hook, isApprovedForAll, plus an exposed `mint`. Multi-transfer
/// and metadata URI are out of scope.
contract MockERC1155 is IERC1155 {
    mapping(uint256 => mapping(address => uint256)) private _balances;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ---- ERC165 ----

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1155).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ---- Mint (test helper) ----

    function mint(address to, uint256 id, uint256 amount) external {
        require(to != address(0), "MockERC1155: mint to zero");
        _balances[id][to] += amount;
        emit TransferSingle(msg.sender, address(0), to, id, amount);
    }

    // ---- ERC1155 ----

    function balanceOf(address account, uint256 id) public view override returns (uint256) {
        require(account != address(0), "MockERC1155: zero address");
        return _balances[id][account];
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory)
    {
        require(accounts.length == ids.length, "MockERC1155: length mismatch");
        uint256[] memory out = new uint256[](accounts.length);
        for (uint256 i = 0; i < accounts.length; i++) {
            out[i] = balanceOf(accounts[i], ids[i]);
        }
        return out;
    }

    function setApprovalForAll(address operator, bool approved) external override {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address account, address operator) public view override returns (bool) {
        return _operatorApprovals[account][operator];
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data)
        external
        override
    {
        require(to != address(0), "MockERC1155: transfer to zero");
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "MockERC1155: not approved");
        uint256 fromBalance = _balances[id][from];
        require(fromBalance >= amount, "MockERC1155: insufficient balance");
        unchecked {
            _balances[id][from] = fromBalance - amount;
        }
        _balances[id][to] += amount;
        emit TransferSingle(msg.sender, from, to, id, amount);
        _checkOnERC1155Received(msg.sender, from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external override {
        require(to != address(0), "MockERC1155: transfer to zero");
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "MockERC1155: not approved");
        require(ids.length == amounts.length, "MockERC1155: length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 fromBalance = _balances[ids[i]][from];
            require(fromBalance >= amounts[i], "MockERC1155: insufficient balance");
            unchecked {
                _balances[ids[i]][from] = fromBalance - amounts[i];
            }
            _balances[ids[i]][to] += amounts[i];
        }
        emit TransferBatch(msg.sender, from, to, ids, amounts);
        _checkOnERC1155BatchReceived(msg.sender, from, to, ids, amounts, data);
    }

    // ---- internal receiver hooks ----

    function _checkOnERC1155Received(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 response) {
                require(response == IERC1155Receiver.onERC1155Received.selector, "MockERC1155: receiver rejected");
            } catch {
                revert("MockERC1155: receiver reverted");
            }
        }
    }

    function _checkOnERC1155BatchReceived(
        address operator,
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (
                bytes4 response
            ) {
                require(response == IERC1155Receiver.onERC1155BatchReceived.selector, "MockERC1155: receiver rejected");
            } catch {
                revert("MockERC1155: receiver reverted");
            }
        }
    }
}
