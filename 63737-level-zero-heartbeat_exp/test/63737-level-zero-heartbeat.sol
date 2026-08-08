// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 63737: Level zero heartbeat blocks claims. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public heartbeat; bool public claimed; function claim() external { require(heartbeat != 0, "zero heartbeat"); claimed = true; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        (bool ok,) = address(bug).call(abi.encodeWithSignature("claim()")); success = !ok;
    }
}


