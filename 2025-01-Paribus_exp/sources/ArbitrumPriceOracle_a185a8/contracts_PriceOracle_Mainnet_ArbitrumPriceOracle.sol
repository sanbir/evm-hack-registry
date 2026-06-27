// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../Impl/ChainlinkPriceOracle.sol";
import "../Impl/UniV2PriceOracle.sol";
import "../Impl/AggregatorOracle.sol";

// arbitrum mainnet price oracle
contract ArbitrumChainlink is L2ChainlinkPriceOracle {
    constructor() public {
        chainlinkDataFeeds[0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = DataFeedInterface.DataFeed(0xd0C7101eACbB49F3deCcCc166d238410D6D46d57, 86400); // WBTC / USD
        chainlinkDataFeeds[0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = DataFeedInterface.DataFeed(0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7, 86400); // USDT / USD
        chainlinkDataFeeds[0x912CE59144191C1204E64559FE8253a0e49E6548] = DataFeedInterface.DataFeed(0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6, 86400); // ARB / USD
        chainlinkDataFeeds[address(0)]                                 = DataFeedInterface.DataFeed(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612, 86400); // ETH / USD
        chainlinkDataFeeds[0x82aF49447D8a07e3bd95BD0d56f35241523fBab1] = DataFeedInterface.DataFeed(0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612, 86400); // WETH / USD
        chainlinkDataFeeds[0xaf88d065e77c8cC2239327C5EDb3A432268e5831] = DataFeedInterface.DataFeed(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3, 86400); // USDC / USD
        chainlinkDataFeeds[0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8] = DataFeedInterface.DataFeed(0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3, 86400); // USDCe / USD

        sequencerUptimeFeed = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    }
}

// arbitrum main-net price oracle
contract ArbitrumPriceOracle is AggregatorOracle {
    constructor(address _algebraTwapSourceOracle) public {
        chainlinkSourceOracle = new ArbitrumChainlink();
        uniV2SourceOracle = new UniV2PriceOracle(this);
        uniV3PriceOracle = new UniV3PriceOracle(this, 0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        camelotV2Oracle = new AlgebraV1PriceOracle(this, 0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15);
        pEtherAddress = 0xAffd437801434643B734D0B2853654876F66f7D7;
        paribusOracle = 0xc8Be723395F6B1f51886947cCaE731a36Df615ba;
        algebraTwapSourceOracle = IAlgebraSingleAssetOracle(_algebraTwapSourceOracle);
    }
}