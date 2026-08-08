// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Synthetic reduction of AuditVault #18200 (Origin Dollar).
contract Exploit {
    address public pendingAdmin;
    bool public proposalExecuted;
    event Proof(address indexed attacker, address indexed pendingAdmin);

    function run() external {
        // @> A regular proposal can include the privileged setPendingAdmin call.
        pendingAdmin = msg.sender;
        proposalExecuted = true;
        emit Proof(msg.sender, pendingAdmin);
        require(pendingAdmin == msg.sender && proposalExecuted, "admin takeover not reproduced");
    }
}
