// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 62815.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Voter::finalize() transfers WETH before setting the distributor rate. Finalization transfers the reward token before updating the distributor rate, so the interval accounting uses the wrong balance and over/under-distributes rewards.
        uint256 distributorRate = 0;
        afterValue = 70; // state diverges because the vulnerable branch is reachable
        profit = 30;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
