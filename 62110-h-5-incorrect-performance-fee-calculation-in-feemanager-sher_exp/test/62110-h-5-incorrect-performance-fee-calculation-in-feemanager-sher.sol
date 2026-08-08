// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Exploit { uint256 public buggyFee; uint256 public correctFee; bool public harmed; event Proof(uint256 buggy,uint256 correct);
    function run() external { uint256 minPrice=100e18; uint256 price=90e18; uint256 totalShares=100; uint256 performanceFee=1e5;
        // @> shares = Math.mulDiv(minPriceD18_ - priceD18, $.performanceFeeD6 * totalShares, 1e24);
        buggyFee=(minPrice-price)*performanceFee*totalShares/1e24; correctFee=(minPrice-price)*performanceFee*totalShares/(1e6*price); harmed=buggyFee!=correctFee; emit Proof(buggyFee,correctFee); require(harmed,"fee formula"); }
}
