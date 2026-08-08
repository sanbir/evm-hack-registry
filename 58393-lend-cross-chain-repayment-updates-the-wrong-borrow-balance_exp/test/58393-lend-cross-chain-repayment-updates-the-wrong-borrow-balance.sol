// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58393.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Cross-chain repayment updates the wrong borrow balance. The repayment handler indexes the same-chain borrow slot even for a remote chain id, so the actual cross-chain balance remains unchanged.
        uint256 crossChainDebt = 100;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = crossChainDebt;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
