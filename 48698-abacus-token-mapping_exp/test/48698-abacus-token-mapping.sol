// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 48698: Abacus tokenMapping inconsistency. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(uint256 => address) public tokenMapping; mapping(uint256 => bool) public exists; function register(uint256 id, address token) external { tokenMapping[id] = token; exists[1] = true; } function isMapped(uint256 id) external view returns (bool) { return exists[id]; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.register(7, address(0xBEEF)); success = !bug.isMapped(7);
    }
}


