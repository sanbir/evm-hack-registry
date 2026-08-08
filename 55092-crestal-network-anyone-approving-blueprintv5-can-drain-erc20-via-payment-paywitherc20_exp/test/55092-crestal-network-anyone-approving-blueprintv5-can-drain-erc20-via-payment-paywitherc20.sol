// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 55092.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Anyone approving BlueprintV5 can drain ERC20 via Payment::payWithERC20. Payment::payWithERC20 trusts an arbitrary payer/spender relationship, so any account that has approved BlueprintV5 can be charged by an untrusted caller.
        uint256 approved = 1000;
        afterValue = approved; // state diverges because the vulnerable branch is reachable
        profit = approved;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
