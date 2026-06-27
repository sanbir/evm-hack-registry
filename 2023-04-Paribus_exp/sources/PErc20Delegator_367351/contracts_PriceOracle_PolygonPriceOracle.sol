// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./Impl/ChainlinkPriceOracle.sol";
import "./Impl/Api3PriceOracle.sol";

contract MumbaiPriceOracle is ChainlinkPriceOracle, Api3PriceOracle {
    constructor() public {
        chainlinkDataFeeds[address(0)] = address(0); // wbtc
        chainlinkDataFeeds[address(0)] = address(0); // eth
        chainlinkDataFeeds[address(0)] = address(0); // weth
        chainlinkDataFeeds[address(0)] = address(0); // dai

        stablecoinsPrices[address(0)] = 1000000000000000000; // usdc == 1 USD
        stablecoinsPrices[address(0)] = 100000000000000000; // pbx == 0.01 USD

        pEtherAddress = address(0);

        api3DataFeedNames[address(0)] = "";
        api3DapiServer = 0x71Da7A936fCaEd1Ee364Df106B12deF6D1Bf1f14;
    }

    function isTokenSupported(address token) public view returns (bool) {
        return ChainlinkPriceOracle.isTokenSupported(token) || Api3PriceOracle.isTokenSupported(token);
    }

    function getPriceOfUnderlying(address token, uint decimals) public view returns (uint) {
        if (ChainlinkPriceOracle.isTokenSupported(token)) return ChainlinkPriceOracle.getPriceOfUnderlying(token, decimals);
        if (Api3PriceOracle.isTokenSupported(token)) return Api3PriceOracle.getPriceOfUnderlying(token, decimals);
        revert("TOKEN_NOT_SUPPORTED");
    }
}
