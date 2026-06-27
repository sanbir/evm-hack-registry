// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "openzeppelin2/ownership/Ownable.sol";
import "../../Interfaces/ChainlinkInterfaces.sol";
import "./SourceOracle.sol";

contract ChainlinkPriceOracle is BaseSourceOracle, Ownable {

    /// @notice underlying address => (underlying asset price data feed, heartbeat)
    mapping(address => DataFeedInterface.DataFeed) public chainlinkDataFeeds;

    /**
      * @notice Adds a Chainlink data feed to the oracle.
      * @param token The address of the token.
      * @param feed The address of the Chainlink data feed.
      * @param heartbeat The heartbeat interval for the Chainlink data feed.
      */
    function addChainlinkFeed(address token, address feed, uint heartbeat) public onlyOwner {
        require(feed != address(0), "invalid feed");
        require(heartbeat > 0, "invalid heartbeat");
        require(chainlinkDataFeeds[token].addr == address(0), "feed already exists");

        chainlinkDataFeeds[token] = DataFeedInterface.DataFeed(feed, heartbeat);
        AggregatorV3Interface priceFeed = AggregatorV3Interface(chainlinkDataFeeds[token].addr);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // the rest of price related validations are done in getTokenPrice
        require(price > 0, "invalid chainlink feed");
    }

    /**
      * @notice Checks if the given token is supported by the Chainlink data feed.
      * @param token The address of the token.
      * @return True if the token is supported, false otherwise.
      */
    function isTokenSupported(address token) public view returns (bool) {
        return chainlinkDataFeeds[token].addr != address(0);
    }

    /**
      * @notice Gets the price of the given token from the Chainlink data feed.
      * @param token The address of the token.
      * @param decimals The number of decimals for the token price.
      * @return The price of the token adjusted to the specified decimals.
      */
    function getTokenPrice(address token, uint decimals) public view returns (uint) {
        require(isTokenSupported(token), "token not supported");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(chainlinkDataFeeds[token].addr);
        (uint80 roundID, int256 price, uint updatedAt, uint timeStamp, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(price > 0, "invalid chainlink answer: price");
        require(price > priceFeed.aggregator().minAnswer(), "invalid chainlink answer: price too low");
        require(price < priceFeed.aggregator().maxAnswer(), "invalid chainlink answer: price too high");
        require(timeStamp > 0, "invalid chainlink answer: timestamp");
        require(answeredInRound >= roundID, "invalid chainlink answer: answeredInRound");
        require(subabs(block.timestamp, updatedAt) < chainlinkDataFeeds[token].heartbeat * 11 / 10, "invalid chainlink answer: updatedAt"); // multiply heartbeat by some slippage factor

        return adjustDecimals(priceFeed.decimals(), decimals, uint(price));
    }
}

/// @dev see https://docs.chain.link/data-feeds/l2-sequencer-feeds
contract L2ChainlinkPriceOracle is ChainlinkPriceOracle {
    /// @notice The address of the Chainlink L2 sequencer uptime feed.
    address public sequencerUptimeFeed;

    /// @notice The grace period time in seconds after the Chainlink L2 sequencer is back up.
    /// @dev This constant is set to 3600 seconds (1 hour).
    uint private constant GRACE_PERIOD_TIME = 3600;

    /**
      * @notice Gets the price of the given token from the Chainlink L2 data feed.
      * @param token The address of the token.
      * @param decimals The number of decimals for the token price.
      * @return The price of the token adjusted to the specified decimals.
      */
    function getTokenPrice(address token, uint decimals) public view returns (uint) {
        (, int256 answer, uint startedAt, , ) = AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();

        // Answer == 0: Sequencer is up
        // Answer == 1: Sequencer is down
        require(answer == 0, "chainlink L2 sequencer is down");

        // Make sure the grace period has passed after the sequencer is back up
        uint timeSinceUp = block.timestamp - startedAt;
        require(timeSinceUp > GRACE_PERIOD_TIME, "chainlink L2 sequencer grace period not over");

        return ChainlinkPriceOracle.getTokenPrice(token, decimals);
    }
}
