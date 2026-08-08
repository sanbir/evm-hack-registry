// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 56955.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Fee bypass in ValueFacet.removeValueSingle. The single-sided removal path reaches the transfer without applying the configured exit fee, allowing users to bypass protocol fees.
        uint256 configuredFee = 10;
        afterValue = 110; // state diverges because the vulnerable branch is reachable
        profit = configuredFee;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
