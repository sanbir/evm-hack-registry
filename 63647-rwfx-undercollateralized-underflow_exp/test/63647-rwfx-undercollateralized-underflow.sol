// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 63647: RWf(x) undercollateralized underflow. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public collateral = 1; uint256 public debt = 2; function loadSwapState() external view returns (uint256) { return collateral - debt; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        (bool ok,) = address(bug).call(abi.encodeWithSignature("loadSwapState()")); success = !ok;
    }
}


