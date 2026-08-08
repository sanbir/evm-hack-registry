// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45457: Autonomint odos data manipulation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public output; function execute(uint256 assembledAmount) external { output = assembledAmount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.execute(999); success = bug.output() == 999;
    }
}


