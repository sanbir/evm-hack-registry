// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58391.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Liquidation validation logic is wrong. The validation condition accepts a healthy position because the comparison is inverted, so a liquidator can seize collateral at spot price.
        uint256 healthyPosition = 1;
        afterValue = 2; // state diverges because the vulnerable branch is reachable
        profit = 1;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
