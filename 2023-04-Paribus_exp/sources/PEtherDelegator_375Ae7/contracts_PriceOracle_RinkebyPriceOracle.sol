// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./Impl/ChainlinkPriceOracle.sol";

contract RinkebyPriceOracle is ChainlinkPriceOracle {
    constructor() public {
        chainlinkDataFeeds[0x37022F97333df61A61595B7cf43b63205290f8Ee] = 0xECe365B379E1dD183B20fc5f022230C044d51404; // wbtc
        chainlinkDataFeeds[address(0)] = 0x8A753747A1Fa494EC906cE90E9f37563A8AF630e; // eth
        chainlinkDataFeeds[0x98a5F1520f7F7fb1e83Fe3398f9aBd151f8C65ed] = 0x8A753747A1Fa494EC906cE90E9f37563A8AF630e; // weth
        chainlinkDataFeeds[0x2Ec4c6fCdBF5F9beECeB1b51848fc2DB1f3a26af] = 0x2bA49Aaa16E6afD2a993473cfB70Fa8559B523cF; // dai
        stablecoinsPrices[0x5B8B635c2665791cf62fe429cB149EaB42A3cEd8] = 1000000000000000000; // usdc == 1 USD
        stablecoinsPrices[0x04A382E64E36D63Dc2bAA837aB5217620732c60A] = 100000000000000000; // pbx == 0.01 USD
        pEtherAddress = 0x2a97aDE05f844802a6DB2a40f547096b464CcF18;
    }
}
