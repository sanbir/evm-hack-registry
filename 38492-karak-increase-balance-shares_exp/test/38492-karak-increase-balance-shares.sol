// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 38492: Karak increaseBalance share loss. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public shares; function increaseBalance(uint256 amount) external { shares += amount / 2; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.increaseBalance(100); success = bug.shares() == 50;
    }
}


