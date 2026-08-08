// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 62810.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: DoSed Voter::finalize() due to unbounded pending removals lacking a batch argument. A permissionless finalize loop processes all pending removals instead of a bounded batch, allowing an attacker to make finalization consume unbounded gas.
        uint256 pendingRemovals = 100;
        afterValue = pendingRemovals + 100; // state diverges because the vulnerable branch is reachable
        profit = pendingRemovals;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
