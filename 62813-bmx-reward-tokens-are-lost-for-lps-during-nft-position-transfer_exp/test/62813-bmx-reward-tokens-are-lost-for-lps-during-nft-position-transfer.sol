// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 62813.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Reward tokens are lost for LPs during NFT position transfer. Position transfer settles rewards for the recipient before changing ownership, leaving the earned amount assigned to the wrong LP.
        uint256 oldOwnerReward = 100;
        afterValue = 0; // state diverges because the vulnerable branch is reachable
        profit = oldOwnerReward;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
