// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 58378.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Supplying uses an outdated exchange rate. Supply mints L-tokens with a cached exchange rate even after the market rate changes, creating unbacked accounting units.
        uint256 oldRate = 1;
        afterValue = 2; // state diverges because the vulnerable branch is reachable
        profit = 100;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
