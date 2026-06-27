// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

interface ParibusOracleInterface_ {
    function getOrRequestTokenPriceWei(address nft, uint tokenId) external returns (uint, uint);
    function getTokenPriceWei(address nft, uint tokenId) external view returns (uint, uint);
    function heartbeat() external view returns (uint);
}
