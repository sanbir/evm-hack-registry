// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61091: Folks Finance mixes stable and variable debt. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public stableBorrow = 40; uint256 public variableBorrow = 60; function liquidate() external { variableBorrow += stableBorrow; stableBorrow = 0; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.liquidate(); success = bug.variableBorrow() == 100 && bug.stableBorrow() == 0;
    }
}


