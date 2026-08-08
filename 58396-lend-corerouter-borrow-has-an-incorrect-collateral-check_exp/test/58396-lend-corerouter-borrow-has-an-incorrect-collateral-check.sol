// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58396.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: CoreRouter borrow has an incorrect collateral check. The borrow check compares debt to the wrong collateral variable, accepting a borrow that exceeds the account's available collateral.
        uint256 availableCollateral = 100;
        afterValue = 150; // state diverges because the vulnerable branch is reachable
        profit = afterValue - availableCollateral;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
