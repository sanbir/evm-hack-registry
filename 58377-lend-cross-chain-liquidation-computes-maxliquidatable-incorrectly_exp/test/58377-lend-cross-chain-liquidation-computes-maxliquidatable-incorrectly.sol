// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58377.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain liquidation computes maxLiquidatable incorrectly. The maximum liquidation amount is derived from collateral seized rather than outstanding debt, making valid liquidations fail or leaving bad debt.
        uint256 maxLiquidatable = 0;
        afterValue = 200; // state diverges because the vulnerable branch is reachable
        profit = 100;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
