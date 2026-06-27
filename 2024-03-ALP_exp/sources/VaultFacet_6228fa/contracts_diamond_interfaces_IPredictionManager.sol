// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

enum Period{MINUTE1, MINUTE5, MINUTE10, MINUTE15, MINUTE30, HOUR1, HOUR2, HOUR3, HOUR4, HOUR6, HOUR8, HOUR12, DAY1}
enum PredictionPairStatus{AVAILABLE, CLOSE_ONLY, CLOSED}

struct PredictionPeriod {
    uint256 maxUpUsd;     // USD 1e18
    uint256 maxDownUsd;   // USD 1e18
    Period period;
    PredictionPairStatus status;
    uint16 winRatio;      // 1e4
    uint16 openFeeP;      // 1e4
    uint16 winCloseFeeP;  // 1e4
    uint16 loseCloseFeeP; // 1e4
}

interface IPredictionManager {

    event AddPredictionPair(address indexed base, string name, PredictionPeriod[] predictionPeriods);
    event RemovePredictionPair(address indexed base);
    event UpdatePredictionPairStatus(address indexed base, PredictionPairStatus status);
    event UpdatePredictionPairPeriodMaxCap(address indexed base, Period indexed period, uint256 maxUpUsd, uint256 maxDownUsd);
    event UpdatePredictionPairPeriodWinRatio(address indexed base, Period indexed period, uint16 winRatio);
    event UpdatePredictionPairPeriodFee(address indexed base, Period indexed period, uint16 openFeeP, uint16 winCloseFeeP, uint16 loseCloseFeeP);
    event AddPeriodForPredictionPair(address indexed base, PredictionPeriod[] predictionPeriods);
    event ReplacePredictionPairPeriod(address indexed base, PredictionPeriod[] predictionPeriods);

    struct PeriodCap {
        Period period;
        uint256 maxUpUsd;     // USD 1e18
        uint256 maxDownUsd;   // USD 1e18
    }

    struct PeriodWinRatio {
        Period period;
        uint16 winRatio;
    }

    struct PeriodFee {
        Period period;
        uint16 openFeeP;      // 1e4
        uint16 winCloseFeeP;  // 1e4
        uint16 loseCloseFeeP; // 1e4
    }

    struct PredictionPairView {
        string name;
        address base;
        PredictionPeriod[] predictionPeriods;
    }

    function addPredictionPair(
        address base, string calldata name, PredictionPeriod[] calldata predictionPeriods
    ) external;

    function removePredictionPair(address base) external;

    function updatePredictionPairStatus(address base, PredictionPairStatus status) external;

    function updatePredictionPairMaxCap(address base, PeriodCap[] calldata periodCaps) external;

    function updatePredictionPairWinRatio(address base, PeriodWinRatio[] calldata periodWinRatios) external;

    function updatePredictionPairFee(address base, PeriodFee[] calldata periodFees) external;

    function addPeriodForPredictionPair(address base, PredictionPeriod[] calldata predictionPeriods) external;

    function replacePredictionPairPeriod(address base, PredictionPeriod[] calldata predictionPeriods) external;

    function getPredictionPairByBase(address base) external returns (PredictionPairView memory);

    function predictionPairs(uint start, uint8 size) external returns (PredictionPairView[] memory);

    function getPredictionPeriod(address base, Period period) external returns (PredictionPeriod memory);
}
