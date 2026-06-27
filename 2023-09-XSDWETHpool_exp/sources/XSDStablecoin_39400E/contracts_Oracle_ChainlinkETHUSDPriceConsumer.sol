// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./AggregatorV3Interface.sol";

contract ChainlinkETHUSDPriceConsumer {

    AggregatorV3Interface internal priceFeed;

    constructor() {
        
    
        //BNB address: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE
        //BNB testnet: 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526
        priceFeed = AggregatorV3Interface(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
    }

    function getDecimals() public view returns (uint8) {
        return priceFeed.decimals();
    }
}