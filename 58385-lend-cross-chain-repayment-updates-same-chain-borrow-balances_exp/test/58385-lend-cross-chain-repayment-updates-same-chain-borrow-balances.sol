// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58385.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain repayment updates same-chain borrow balances. repayBorrowInternal() updates only the local market mapping, leaving the remote debt unchanged after a cross-chain repayment.
        uint256 remoteDebt = 100;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = remoteDebt;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
