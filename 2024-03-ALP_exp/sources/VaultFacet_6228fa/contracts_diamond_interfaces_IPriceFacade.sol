// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

enum RequestType {CLOSE, OPEN, PREDICT}

interface IPriceFacade {

    struct Config {
        uint16 lowPriceGapP;
        uint16 highPriceGapP;
        uint16 maxDelay;
        uint16 triggerLowPriceGapP;   // 1e4
        uint16 triggerHighPriceGapP;  // 1e4
    }

    function setLowAndHighPriceGapP(uint16 lowPriceGapP, uint16 highPriceGapP) external;

    function setTriggerLowAndHighPriceGapP(uint16 triggerLowPriceGapP, uint16 triggerHighPriceGapP) external;

    function setMaxDelay(uint16 maxDelay) external;

    function getPriceFacadeConfig() external view returns (Config memory);

    function getPrice(address token) external view returns (uint256);

    function getPriceFromCacheOrOracle(address token) external view returns (uint64 price, uint40 updatedAt);

    function requestPrice(bytes32 tradeHash, address token, RequestType requestType) external;

    function requestPriceCallback(bytes32 requestId, uint64 price) external;

    function confirmTriggerPrice(address token, uint64 price) external returns (bool, uint64, uint64);
}
