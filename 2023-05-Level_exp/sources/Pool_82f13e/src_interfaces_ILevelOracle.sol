pragma solidity >= 0.8.0;

interface ILevelOracle {
    /**
     * @notice get price of single token
     * @param token address of token to consult
     * @param max if true returns max price and vice versa
     */
    function getPrice(address token, bool max) external view returns (uint256);

    function getMultiplePrices(address[] calldata tokens, bool max) external view returns (uint256[] memory);

    /**
     * @notice returns chainlink price used when liquidate
     */
    function getReferencePrice(address token) external view returns (uint256);

    /**
     * @notice returns timestamp of last posted price
     */
    function lastAnswerTimestamp(address token) external view returns (uint256);
}
