// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 65649.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: processNormalSupplyAction permits an uncapped withdrawal. The normal-supply action does not cap the requested withdrawal by the user's tracked shares, allowing a caller to withdraw more than was supplied.
        uint256 trackedShares = 100;
        afterValue = 1000; // state diverges because the vulnerable branch is reachable
        profit = afterValue - trackedShares;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
