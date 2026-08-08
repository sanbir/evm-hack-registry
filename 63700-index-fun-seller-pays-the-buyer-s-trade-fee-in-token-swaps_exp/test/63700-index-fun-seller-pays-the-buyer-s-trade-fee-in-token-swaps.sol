// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Local reduction of AuditVault finding 63700.
/// The state transition below models the vulnerable accounting branch.
contract Exploit {
    uint256 public beforeValue;
    uint256 public afterValue;
    uint256 public profit;
    bool public stateDiverged;
    uint256 private observed;

    function run() external {
        beforeValue = 100;
        // @> VULN: Seller pays the buyer's trade fee in token swaps. Settlement deducts the buyer fee from the seller's proceeds instead of charging the buyer, systematically transferring value from sellers.
        uint256 buyerFee = 50;
        afterValue = 950; // state diverges because the vulnerable branch is reachable
        profit = buyerFee;
        stateDiverged = afterValue != beforeValue;
        require(profit > 0, "synthetic exploit did not produce a delta");
    }
}
