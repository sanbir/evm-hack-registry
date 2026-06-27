// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStrcPriceOracle
 * @notice Interface for the STRC price oracle contract
 * @dev Provides validated STRC price data with staleness and bounds checking.
 * This contract wraps a Chainlink-compatible oracle and adds additional validation.
 */
interface IStrcPriceOracle {
    /**
     * @dev Thrown when the oracle returns an invalid, stale, or out-of-bounds price.
     */
    error InvalidOraclePrice();

    /**
     * @dev Thrown when a zero address is provided where a valid address is required.
     */
    error InvalidZeroAddress();

    /**
     * @dev Thrown when the staleness value exceeds MAX_STALENESS.
     */
    error InvalidStaleness();

    /**
     * @dev Thrown when invalid price bounds are provided (minPrice must be > 0 and < maxPrice).
     */
    error InvalidPriceBounds();

    /**
     * @dev Emitted when the maximum price staleness setting is updated.
     * @param newStaleness The new staleness value in seconds.
     */
    event MaxPriceStalenessUpdated(uint256 newStaleness);

    /**
     * @dev Emitted when the acceptable price bounds are updated.
     * @param newMinPrice The new minimum acceptable price.
     * @param newMaxPrice The new maximum acceptable price.
     */
    event PriceBoundsUpdated(uint256 newMinPrice, uint256 newMaxPrice);

    /**
     * @dev Emitted when the oracle address is updated.
     * @param oldOracle The previous oracle address.
     * @param newOracle The new oracle address.
     */
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    /**
     * @notice Updates the price oracle address.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * @param newOracle The new oracle address. Cannot be the zero address.
     */
    function updateOracle(address newOracle) external;

    /**
     * @notice Updates the maximum allowed price staleness.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * The new staleness value must not exceed MAX_STALENESS.
     * @param newStaleness The new staleness value in seconds.
     */
    function setMaxPriceStaleness(uint256 newStaleness) external;

    /**
     * @notice Updates the acceptable price bounds for oracle validation.
     * @dev Only callable by addresses with the DEFAULT_ADMIN_ROLE.
     * The minPrice must be greater than 0 and less than maxPrice.
     * @param newMinPrice The new minimum acceptable price.
     * @param newMaxPrice The new maximum acceptable price.
     */
    function setPriceBounds(uint256 newMinPrice, uint256 newMaxPrice) external;

    /**
     * @notice Returns the current oracle address.
     * @return The address of the price oracle contract.
     */
    function getOracle() external view returns (address);

    /**
     * @notice Fetches the latest STRC price from the oracle.
     * @dev Uses latestRoundData for staleness checks (Chainlink recommended).
     * Reverts if the oracle address is zero, the price is stale, negative, or out of bounds.
     * @return price The latest price from the oracle (scaled by oracle decimals).
     * @return oracleDecimals The number of decimals in the price.
     */
    function getPrice() external view returns (uint256 price, uint8 oracleDecimals);

    /**
     * @notice Returns the maximum allowed staleness setting.
     * @return The maximum staleness constant (6 hours).
     */
    function MAX_STALENESS() external view returns (uint256);

    /**
     * @notice Returns the current maximum price staleness setting.
     * @return The maximum allowed staleness in seconds.
     */
    function maxPriceStaleness() external view returns (uint256);

    /**
     * @notice Returns the minimum acceptable price from the oracle.
     * @return The minimum price (default $20 with 8 decimals).
     */
    function minPrice() external view returns (uint256);

    /**
     * @notice Returns the maximum acceptable price from the oracle.
     * @return The maximum price (default $150 with 8 decimals).
     */
    function maxPrice() external view returns (uint256);
}
