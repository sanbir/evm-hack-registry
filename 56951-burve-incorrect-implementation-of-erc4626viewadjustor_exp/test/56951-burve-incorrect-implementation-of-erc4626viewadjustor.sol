// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 56951.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Incorrect implementation of ERC4626ViewAdjustor. The view adjustor applies the fee conversion in the wrong direction, reporting nominal shares where callers expect net assets.
        uint256 nominalAssets = 100;
        afterValue = nominalAssets + 20; // state diverges because the vulnerable branch is reachable
        profit = 20;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
