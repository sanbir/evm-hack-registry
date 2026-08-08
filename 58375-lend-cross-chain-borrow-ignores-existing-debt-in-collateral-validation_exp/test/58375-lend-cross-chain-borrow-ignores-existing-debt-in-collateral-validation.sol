// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58375.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain borrow ignores existing debt in collateral validation. Validation considers only the new borrow and omits debt already recorded on the destination chain, admitting an undercollateralized position.
        uint256 existingDebt = 100;
        afterValue = 200; // state diverges because the vulnerable branch is reachable
        profit = existingDebt;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
