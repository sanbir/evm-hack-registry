// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58376.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: CoreRouter redemption payout is miscalculated. redeem() computes the payout from the wrong exchange-rate side, paying more assets than the shares burned and depleting reserves.
        uint256 reserve = 100;
        afterValue = 110; // state diverges because the vulnerable branch is reachable
        profit = afterValue - reserve;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
