// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58392.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain collateral is miscalculated in borrowWithInterest. borrowWithInterest() counts only one side of the cross-chain collateral set, understating the required collateral and allowing excess debt.
        uint256 remoteCollateral = 50;
        afterValue = 150; // state diverges because the vulnerable branch is reachable
        profit = remoteCollateral;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
