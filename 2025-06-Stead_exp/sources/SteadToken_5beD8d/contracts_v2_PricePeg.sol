// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
// The comments are inserted during the auditing process as part of the internal 
// documentation here the meaning of the tags:
// TBC: to be changed
// GO: Gas optimization
// BP: Best practice
// comments without tag may be kept as documentation of the source code

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PricePeg {
    AggregatorV3Interface internal daiUsdPriceFeed;
    AggregatorV3Interface internal usdtUsdPriceFeed;
    AggregatorV3Interface internal usdcUsdPriceFeed;
    //TBC: the addresses must be changed probably for the main net.
    constructor() {
        daiUsdPriceFeed = AggregatorV3Interface(
            0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB
        );
        usdtUsdPriceFeed = AggregatorV3Interface(
            0x3E7d1eAB13ad0104d2750B8863b489D65364e32D
        );
        usdcUsdPriceFeed = AggregatorV3Interface(
            0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3
        );
    }

    /**
     * Returns the latest answer.
     */
     // BP: the function name seems wrong, it return DAI price non ETH, it should be replace to avoid confusion
    function getEthUsdPrice() public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = daiUsdPriceFeed.latestRoundData();
        return answer;
    }

    function getUsdUsdtPrice() public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = usdtUsdPriceFeed.latestRoundData();
        return answer;
    }

    function getUsdUsdcPrice() public view returns (int) {
        // prettier-ignore
        (
            /* uint80 roundID */,
            int answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = usdtUsdPriceFeed.latestRoundData();
        return answer;
    }
}
