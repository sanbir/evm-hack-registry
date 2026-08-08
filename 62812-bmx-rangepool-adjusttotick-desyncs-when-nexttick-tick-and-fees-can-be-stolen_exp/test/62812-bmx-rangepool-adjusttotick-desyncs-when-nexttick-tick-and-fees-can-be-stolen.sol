// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 62812.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: RangePool::adjustToTick() desyncs when nextTick == tick and fees can be stolen. The equal-tick branch skips the reserve update, so the accounting view and the actual range pool diverge and the stale fee balance can be taken.
        uint256 trackedFees = 100;
        afterValue = trackedFees + 20; // state diverges because the vulnerable branch is reachable
        profit = afterValue - trackedFees;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
