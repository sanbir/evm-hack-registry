// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./Impl/ChainlinkPriceOracle.sol";

contract ArbitrumGoerliPriceOracle is L2ChainlinkPriceOracle {
    constructor() public {
        chainlinkDataFeeds[0xFf8CbB3E593cf9003A43Ff4A77E7832c8B620571] = 0x6550bc2301936011c1334555e62A87705A81C12C; // wbtc
        chainlinkDataFeeds[0xeBD32BFc3e0D80E9ed34A97e3083e7a5C63C2d89] = 0x0a023a3423D9b27A0BE48c768CCF2dD7877fEf5E; // usdt

        chainlinkDataFeeds[address(0)] = 0x62CAe0FA2da220f43a51F86Db2EDb36DcA9A5A08; // eth
        pEtherAddress = 0x3c2cf7aAD5804cA3c786E2640Db150043437b6dA;

        sequencerUptimeFeed = 0x4da69F028a5790fCCAfe81a75C0D24f46ceCDd69;
    }
}

contract ArbitrumPriceOracle is L2ChainlinkPriceOracle {
    constructor() public {
        chainlinkDataFeeds[0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f] = 0x6ce185860a4963106506C203335A2910413708e9; // wbtc
        chainlinkDataFeeds[0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9] = 0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7; // usdt

        chainlinkDataFeeds[address(0)] = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // eth
        pEtherAddress = 0x375Ae76F0450293e50876D0e5bDC3022CAb23198;

        sequencerUptimeFeed = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    }
}
