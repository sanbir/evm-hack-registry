// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./Impl/ChainlinkPriceOracle.sol";
import "./Impl/NFTPriceOracle.sol";

contract GoerliPriceOracle is ChainlinkPriceOracle, NFTPriceOracle {
    constructor() public {
        chainlinkDataFeeds[0x2511cBfcb3a4581C128dD6e0196a618f25E1a10B] = 0xA39434A63A52E749F02807ae27335515BA4b07F7; // wbtc
        chainlinkDataFeeds[0x6E3c9208bA7D4e6950DC540a483976774Cf00D77] = 0x48731cF7e84dc94C5f84577882c14Be11a5B7456; // link
        chainlinkDataFeeds[address(0)] = 0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e; // eth
        stablecoinsPrices[0x06698e5d51bd05Eb3551a7Cf9DcA881aB069A9Ba] = 1000000000000000000; // usdc == 1 USD
        pEtherAddress = 0x9517c419f5b9A9C7e876B066543d36d798c23fDD;
    }
}
