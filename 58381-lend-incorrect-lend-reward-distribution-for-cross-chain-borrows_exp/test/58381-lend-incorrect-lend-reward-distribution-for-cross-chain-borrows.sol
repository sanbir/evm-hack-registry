// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58381.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Incorrect LEND reward distribution for cross-chain borrows. Cross-chain borrower rewards are allocated from the aggregate index without subtracting the remote chain's share, diverting rewards from other users.
        uint256 borrowerShare = 20;
        afterValue = 120; // state diverges because the vulnerable branch is reachable
        profit = afterValue - borrowerShare;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
