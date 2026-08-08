// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61051: Folks Finance loan-health underestimation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public deposit = 1; uint256 public debt = 100; function getLoanLiquidity() external view returns (uint256) { return deposit * 1000; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        success = bug.getLoanLiquidity() > bug.debt();
    }
}


