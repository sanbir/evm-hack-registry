// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

interface ISteadToken {
    struct Token {
        uint256 maxSupply;
        uint256 decimals;
        uint256 basePrice;
        uint256 baseTime;
    }

}
