// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../PriceOracle/Impl/ChainlinkPriceOracle.sol";
import "../PriceOracle/Impl/NFTPriceOracle.sol";
import "../PriceOracle/Impl/Api3PriceOracle.sol";

contract ChainlinkPriceOracleMock is ChainlinkPriceOracle, NFTPriceOracle {
    constructor(address pwbtcDataFeed, address pethDataFeed, address wbtcAddress, address wethAddress, address stablecoinAddress, uint256 stablecoinPrice, address pethAddress) public {
        chainlinkDataFeeds[wbtcAddress] = pwbtcDataFeed;
        chainlinkDataFeeds[wethAddress] = pethDataFeed;
        chainlinkDataFeeds[address(0)] = pethDataFeed;
        stablecoinsPrices[stablecoinAddress] = stablecoinPrice;
        pEtherAddress = pethAddress;
    }
}

contract Api3PriceOracleMock is Api3PriceOracle, NFTPriceOracle {
    constructor(address _api3DapiServer, address wbtcAddress) public {
        api3DapiServer = _api3DapiServer;
        api3DataFeedNames[wbtcAddress] = "WBTC/USD";
    }
}
