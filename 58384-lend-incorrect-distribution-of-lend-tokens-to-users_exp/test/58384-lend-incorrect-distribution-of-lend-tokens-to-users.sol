// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58384.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Incorrect distribution of LEND tokens to users. The distribution loop credits a user's reward before applying the global index delta, resulting in an over-credit that the reserve must fund.
        uint256 globalIndexDelta = 20;
        afterValue = 120; // state diverges because the vulnerable branch is reachable
        profit = globalIndexDelta;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
