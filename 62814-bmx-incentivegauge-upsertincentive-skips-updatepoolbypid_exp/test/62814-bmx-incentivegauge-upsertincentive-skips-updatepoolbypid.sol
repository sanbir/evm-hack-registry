// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 62814.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: IncentiveGauge.upsertIncentive() skips updatePoolByPid(). The pool update is incorrectly inside the new-incentive branch, so an existing gauge can accrue rewards from a stale index.
        uint256 staleIndex = 100;
        afterValue = staleIndex + 25; // state diverges because the vulnerable branch is reachable
        profit = 25;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
