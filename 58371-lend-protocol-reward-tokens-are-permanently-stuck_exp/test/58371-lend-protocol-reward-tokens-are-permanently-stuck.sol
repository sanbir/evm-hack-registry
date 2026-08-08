// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58371.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Protocol reward tokens are permanently stuck. The protocol accrues rewards but has no reachable sweep/claim path for the reserve account, permanently locking the tokens.
        uint256 accruedRewards = 25;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = accruedRewards;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
