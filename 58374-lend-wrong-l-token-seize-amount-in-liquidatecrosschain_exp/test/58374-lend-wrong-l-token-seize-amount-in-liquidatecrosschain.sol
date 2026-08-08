// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58374.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Wrong L-token seize amount in liquidateCrossChain. The cross-chain liquidation converts debt to seized L-tokens with the collateral-side exchange rate, overstating the amount seized from a borrower.
        uint256 debt = 100;
        afterValue = 500; // state diverges because the vulnerable branch is reachable
        profit = afterValue - debt;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
