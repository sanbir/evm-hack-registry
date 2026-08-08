// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58386.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Liquidating CoreRouter can cause excess borrower loss. The router applies the seized collateral amount as repayment and charges the borrower for more debt than the liquidator paid.
        uint256 repayment = 100;
        afterValue = 150; // state diverges because the vulnerable branch is reachable
        profit = afterValue - repayment;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
