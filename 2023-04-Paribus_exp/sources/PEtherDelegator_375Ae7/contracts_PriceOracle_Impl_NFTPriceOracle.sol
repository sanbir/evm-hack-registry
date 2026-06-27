// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PriceOracleCommonImpl.sol";

// NFT TODO NFTPriceOracle
contract NFTPriceOracle is PriceOracleCommonImpl {
    // 18 decimals
    function getUnderlyingNFTPrice(PNFTToken, uint256) public view returns (uint) {
        assert(false);
    }

    function isNFTCollectionSupported(address) public view returns (bool) {
        return false;
    }
}
