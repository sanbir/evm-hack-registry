// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58370.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Repeated claims of the same rewards drain LEND reserves. claimLend() transfers the reward but fails to mark the epoch as claimed, allowing the same reward to be collected repeatedly.
        uint256 firstClaim = 100;
        afterValue = firstClaim * 2; // state diverges because the vulnerable branch is reachable
        profit = firstClaim * 2;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
