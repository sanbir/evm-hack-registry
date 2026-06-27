// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../PNFTToken/PNFTToken.sol";
import "../PToken/PToken.sol";

contract IOracle {
    using SafeMath for uint;

    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /**
      * @notice Get the price of a given token
      * @param token The token. Use address(0) for native token (like ETH).
      * @param decimals Wanted decimals
      * @return The price of the token with a given decimals
      */
    function getPriceOfUnderlying(address token, uint decimals) public view returns (uint);

    /**
      * @notice Get the price of underlying pToken asset.
      * @param pToken The pToken
      * @return The price of pToken.underlying(). Decimals: 36 - underlyingDecimals
      */
    function getUnderlyingPrice(PToken pToken) public view returns (uint);

    /** @notice Check whether pToken is supported by this oracle and we've got a price for its underlying asset
      * @param pToken The token to check
      */
    function isPTokenSupported(PToken pToken) public view returns (bool);
}

contract IOracleNFT {
    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /**
     * @notice Get the price of the underlying asset of a given PNFTToken
     * @param pNFTToken The PNFTToken
     * @param tokenId The token ID of the NFT
     * @return The price of the underlying asset
     */
    function getUnderlyingNFTPrice(PNFTToken pNFTToken, uint tokenId) external view returns (uint);
    /**
      * @notice Get or request the price of the underlying asset of a given PNFTToken
      * @param pNFTToken The PNFTToken
      * @param tokenId The token ID of the NFT
      * @return The price of the underlying asset
      */

    function getOrRequestUnderlyingNFTPrice(PNFTToken pNFTToken, uint tokenId) external returns (uint);
    /**
      * @notice Get the price of ETH
      * @return The price of ETH
      */
    function getETHPrice() internal view returns (uint);
}

contract ISourceOracle {
    /// @notice Get the price of a given token
    /// @param token The token
    /// @param decimals Wanted decimals
    /// @return The price of the token with a given decimals
    function getTokenPrice(address token, uint decimals) public view returns (uint);

    /** @notice Check whether token is supported by this oracle and we've got a price for it
      * @param token The token to check
      */
    function isTokenSupported(address token) public view returns (bool);
}

contract INFPOracle {
     /**
       * @notice Check whether a given position is supported by this oracle
       * @param tokenId The token ID of the position
       * @return True if the position is supported, false otherwise
       */

    function isPositionSupported(uint tokenId) external view returns (bool);
    /**
      * @notice Get the price of a given position
      * @param tokenId The token ID of the position
      * @return The price of the position
      */
    function getPositionPrice(uint tokenId) external view returns (uint);
}