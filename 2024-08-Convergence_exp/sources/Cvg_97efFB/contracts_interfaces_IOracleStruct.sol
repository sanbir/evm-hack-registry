// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IOracleStruct {
    enum PoolType {
        NOT_INIT,
        STABLE,
        CURVE_DUO,
        CURVE_TRI,
        UNI_V3,
        UNI_V2
    }

    struct StableParams {
        AggregatorV3Interface aggregatorOracle;
        uint40 deltaLimitOracle; // 5 % => 500 & 100 % => 10 000
        uint56 maxLastUpdate; // Buffer time before a not updated price is considered as stale
        uint128 minPrice;
        uint128 maxPrice;
    }

    struct CurveDuoParams {
        bool isReversed;
        bool isEthPriceRelated;
        address poolAddress;
        uint40 deltaLimitOracle; // 5 % => 500 & 100 % => 10 000
        uint40 maxLastUpdate; // Buffer time before a not updated price is considered as stale
        uint128 minPrice;
        uint128 maxPrice;
        address[] stablesToCheck;
    }

    struct CurveTriParams {
        bool isReversed;
        bool isEthPriceRelated;
        address poolAddress;
        uint40 deltaLimitOracle;
        uint40 maxLastUpdate;
        uint8 k;
        uint120 minPrice;
        uint128 maxPrice;
        address[] stablesToCheck;
    }

    struct UniV2Params {
        bool isReversed;
        bool isEthPriceRelated;
        address poolAddress;
        uint80 deltaLimitOracle;
        uint96 maxLastUpdate;
        AggregatorV3Interface aggregatorOracle;
        uint128 minPrice;
        uint128 maxPrice;
        address[] stablesToCheck;
    }

    struct UniV3Params {
        bool isReversed;
        bool isEthPriceRelated;
        address poolAddress;
        uint80 deltaLimitOracle;
        uint80 maxLastUpdate;
        uint16 twap;
        AggregatorV3Interface aggregatorOracle;
        uint128 minPrice;
        uint128 maxPrice;
        address[] stablesToCheck;
    }
}
