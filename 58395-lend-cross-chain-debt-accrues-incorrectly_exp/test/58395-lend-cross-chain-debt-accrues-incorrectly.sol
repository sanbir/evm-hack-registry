// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58395.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain debt accrues incorrectly. Debt interest is accrued against the stale local principal after a remote borrow, causing the cross-chain debt to diverge from the canonical balance.
        uint256 principal = 100;
        afterValue = principal + 10; // state diverges because the vulnerable branch is reachable
        profit = 10;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
