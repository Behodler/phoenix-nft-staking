// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPausable} from "pauser/interfaces/IPausable.sol";

contract NFTStaker is Ownable, Pausable, IPausable {
    address public pauser;

    event PauserChanged(
        address indexed previousPauser,
        address indexed newPauser
    );

    modifier onlyPauser() {
        require(msg.sender == pauser, "NFTStaker: caller is not pauser");
        _;
    }

    constructor() Ownable(msg.sender) {}

    function setPauser(address newPauser) external onlyOwner {
        emit PauserChanged(pauser, newPauser);
        pauser = newPauser;
    }

    function pause() external onlyPauser {
        _pause();
    }

    function unpause() external onlyPauser {
        _unpause();
    }
}
