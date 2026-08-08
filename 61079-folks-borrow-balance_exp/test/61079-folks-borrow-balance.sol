// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61079: Folks Finance borrow balance omits interest. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public principal = 100; uint256 public interest = 25; function getLoanLiquidity() external view returns (uint256) { return principal; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        success = bug.getLoanLiquidity() < bug.principal() + bug.interest();
    }
}


