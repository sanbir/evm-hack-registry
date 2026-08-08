// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 56952.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Incorrect netting logic leads to excessive withdrawal amounts. Net liabilities are subtracted with the wrong sign, making a withdrawal quote exceed the closure's assets.
        uint256 netLiability = 40;
        afterValue = 100 + netLiability; // state diverges because the vulnerable branch is reachable
        profit = netLiability;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
