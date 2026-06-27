// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AggregatorV3Interface
 * @notice Chainlink 价格预言机最小接口。
 * @dev 项目只依赖 latestRoundData() 读取价格和更新时间，用于 BNB/USD 折算。
 */
interface AggregatorV3Interface {
    /**
     * @notice 返回最新轮次价格数据。
     * @dev answer 为价格，updatedAt 为价格更新时间；核心合约会校验价格有效性和时效性。
     */
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}
