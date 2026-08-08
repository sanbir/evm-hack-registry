// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 50685: Mismatching data location during inheritance. Reduced local model preserves the reported state transition.

contract Vulnerable {
    bytes public last; function handle(bytes calldata data) external { last = data; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.handle(hex"1234"); success = bug.last().length == 2;
    }
}


