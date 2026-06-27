// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Period} from "./IPredictionManager.sol";

struct PendingPrediction {
    address tokenIn;
    uint96 amountIn;     // tokenIn decimals
    address predictionPairBase;
    uint96 openFee;      // tokenIn decimals
    address user;
    uint64 price;        // 1e8
    uint24 broker;
    bool isUp;
    uint128 blockNumber;
    Period period;
}

struct OpenPrediction {
    address tokenIn;
    uint96 betAmount;      // tokenIn decimals
    address predictionPairBase;
    uint96 openFee;        // tokenIn decimals
    address user;
    uint96 betAmountUsd;
    uint32 userOpenPredictIndex;
    uint64 entryPrice;     // 1e8
    uint40 startTime;
    uint24 broker;
    bool isUp;
    Period period;
}

struct PredictionMarket {
    uint96 upUsd;
    uint96 downUsd;
}

interface IPredictUpDown {

    event PredictAndBetPending(address indexed user, uint256 indexed id, PendingPrediction pp);
    event PendingPredictionRefund(address indexed user, uint256 indexed id, PredictionRefund refund);
    event PredictAndBet(address indexed user, uint256 indexed id, OpenPrediction op);
    event SettlePredictionReject(uint256 indexed id, Period period, uint256 correctTime);
    event SettlePredictionSuccessful(
        uint256 indexed id, bool win, uint256 endPrice, address token, uint256 profitOrLoss, uint256 closeFee
    );

    enum PredictionRefund{NO, FEED_DELAY, USER_PRICE}

    struct PredictionInput {
        address predictionPairBase;
        bool isUp;
        Period period;
        address tokenIn;
        uint96 amountIn;
        uint64 price;
        uint24 broker;
    }

    struct SettlePrediction {
        uint256 id;
        uint64 price;
    }

    struct PredictionView {
        uint256 id;
        address tokenIn;
        uint96 betAmount;      // tokenIn decimals
        address predictionPairBase;
        uint96 openFee;        // tokenIn decimals
        uint64 entryPrice;     // 1e8
        uint40 startTime;
        bool isUp;
        Period period;
    }

    function predictAndBet(PredictionInput memory pi) external;

    function predictAndBetBNB(PredictionInput memory pi) external payable;

    function predictionCallback(bytes32 id, uint256 price) external;

    function settlePredictions(SettlePrediction[] calldata) external;

    function getPredictionById(uint256 id) external view returns (PredictionView memory);

    function getPredictions(address user, address predictionPairBase) external view returns (PredictionView[] memory);

    function getPredictionMarket(
        address predictionPairBase, Period[] calldata periods
    ) external view returns (PredictionMarket[] memory);
}
