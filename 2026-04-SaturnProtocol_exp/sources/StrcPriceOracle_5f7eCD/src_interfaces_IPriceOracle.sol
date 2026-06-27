// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IPriceOracle
 * @dev Interface for price oracle (Chainlink-compatible).
 */
interface IPriceOracle {
    /**
     * @dev Returns the latest round data from the oracle.
     * @return roundId The round ID.
     * @return answer The price answer.
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp when the round was updated.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @dev Returns the number of decimals in the price.
     * @return The number of decimals.
     */
    function decimals() external view returns (uint8);
}
