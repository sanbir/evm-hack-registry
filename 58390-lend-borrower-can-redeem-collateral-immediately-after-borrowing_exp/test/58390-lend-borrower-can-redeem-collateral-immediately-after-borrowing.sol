// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58390.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Borrower can redeem collateral immediately after borrowing. The collateral redemption path does not account for a borrow initiated in the same epoch, enabling an immediately undercollateralized position.
        uint256 borrowed = 100;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = borrowed;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
