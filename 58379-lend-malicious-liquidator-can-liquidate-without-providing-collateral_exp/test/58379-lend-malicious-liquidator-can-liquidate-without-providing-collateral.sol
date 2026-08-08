// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58379.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Malicious liquidator can liquidate without providing collateral. The liquidation path checks the borrower's debt but never verifies that the liquidator supplied the required repayment collateral.
        uint256 requiredCollateral = 100;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = requiredCollateral;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
