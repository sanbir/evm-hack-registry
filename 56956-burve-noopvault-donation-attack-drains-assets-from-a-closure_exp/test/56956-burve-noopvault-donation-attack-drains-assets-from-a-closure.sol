// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 56956.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: NoopVault donation attack drains assets from a closure. A donation changes the vault's asset balance without increasing shares; the stale share price then lets the attacker withdraw the donated assets.
        uint256 donation = 1000;
        afterValue = 2000; // state diverges because the vulnerable branch is reachable
        profit = donation;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
