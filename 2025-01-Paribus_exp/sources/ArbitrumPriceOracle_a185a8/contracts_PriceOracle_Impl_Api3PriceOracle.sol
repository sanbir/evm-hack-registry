// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "openzeppelin2/ownership/Ownable.sol";
import "../../Interfaces/Api3Interfaces.sol";
import "./SourceOracle.sol";

contract Api3PriceOracle is BaseSourceOracle, Ownable  {
    /// @notice underlying address => data feed proxy contract address
    mapping(address => DataFeedInterface.DataFeed) public api3DataFeeds;

    /**
      * @notice Adds an API3 data feed to the oracle.
      * @param token The address of the token.
      * @param dataFeedProxy The name of the API3 data feed.
      */
    function addApi3Feed(address token, address dataFeedProxy, uint heartbeat) public onlyOwner {
        require(token != address(0), "invalid token");
        require(heartbeat > 0, "invalid heartbeat");
        require(api3DataFeeds[token].addr == address(0), "feed already exists");
        api3DataFeeds[token] = DataFeedInterface.DataFeed(dataFeedProxy, heartbeat);

        (int price,) = Api3ProxyInterface(api3DataFeeds[token].addr).read();
        require(price > 0, "invalid api3 feed");
    }

    /**
      * @notice Checks if the given token is supported by the API3 data feed.
      * @param token The address of the token.
      * @return True if the token is supported, false otherwise.
      */
    function isTokenSupported(address token) public view returns (bool) {
        return api3DataFeeds[token].addr != address(0);
    }

    /**
      * @notice Gets the price of the given token from the API3 data feed.
      * @param token The address of the token.
      * @param decimals The number of decimals for the token price.
      * @return The price of the token adjusted to the specified decimals.
      */
    function getTokenPrice(address token, uint decimals) public view returns (uint) {
        require(isTokenSupported(token), "token not supported");

        (int224 price, uint32 timestamp) = Api3ProxyInterface(api3DataFeeds[token].addr).read();
        require(price > 0, "invalid api3 answer: price");
        require(timestamp > 0, "invalid api3 answer: timestamp");
        require(subabs(block.timestamp, timestamp) <= api3DataFeeds[token].heartbeat, "invalid api3 answer: heartbeat"); // multiply heartbeat by some slippage factor

        // Api3 always returns prices in 18 decimals
        return adjustDecimals(18, decimals, uint(price));
    }
}
