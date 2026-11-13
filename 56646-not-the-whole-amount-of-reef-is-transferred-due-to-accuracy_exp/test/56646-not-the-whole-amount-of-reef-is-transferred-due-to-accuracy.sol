// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SqwidMarketplace — Zokyo, 2022-06-16.
    enterRaffle divides msg.value by 1e18 and keeps the integer REEF.
    endRaffle multiplies that integer by 1e18 and sends only that.
    2.5 REEF in becomes 2 REEF out. 0.5 REEF stays in the contract.
    The control sends msg.value through with no division. Nothing sticks.
*/

contract Exploit {
    address public constant SELLER = 0x3333333333333333333333333333333333333333;

    uint256 public entered;
    uint256 public wholeReef;
    uint256 public payout;
    uint256 public stuck;

    function run() external payable {
        entered = msg.value;
        // @> VULN: msg.value / 1e18 drops the fractional REEF
        wholeReef = msg.value / 1e18;
        payout = wholeReef * 1e18;
        stuck = entered - payout;
        (bool ok,) = payable(SELLER).call{value: payout}("");
        require(ok, "pay seller");
        require(entered == 2.5 ether, "entered");
        require(wholeReef == 2, "whole");
        require(payout == 2 ether, "payout");
        require(stuck == 0.5 ether, "stuck");
        require(address(this).balance == stuck, "balance");
        require(SELLER.balance == payout, "seller");
    }
}

contract RaffleFixed {
    address public immutable seller;
    uint256 public payout;
    uint256 public stuck;

    constructor(address _seller) {
        seller = _seller;
    }

    function run() external payable {
        payout = msg.value;
        stuck = address(this).balance - payout;
        (bool ok,) = payable(seller).call{value: payout}("");
        require(ok, "pay seller");
    }
}
