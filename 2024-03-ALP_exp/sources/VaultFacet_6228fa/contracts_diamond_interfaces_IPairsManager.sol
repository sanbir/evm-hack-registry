// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./IFeeManager.sol";
import "./ISlippageManager.sol";
import "../libraries/LibPairsManager.sol";

interface IPairsManager {
    enum PairType{CRYPTO, STOCKS, FOREX, INDICES, COMMODITIES}
    enum PairStatus{AVAILABLE, REDUCE_ONLY, CLOSE}

    struct PairSimple {
        // BTC/USD
        string name;
        // BTC address
        address base;
        PairType pairType;
        PairStatus status;
    }

    struct PairView {
        // BTC/USD
        string name;
        // BTC address
        address base;
        uint16 basePosition;
        PairType pairType;
        PairStatus status;
        uint256 maxLongOiUsd;
        uint256 maxShortOiUsd;
        uint256 fundingFeePerBlockP;  // 1e18
        uint256 minFundingFeeR;       // 1e18
        uint256 maxFundingFeeR;       // 1e18

        LibPairsManager.LeverageMargin[] leverageMargins;

        uint16 slippageConfigIndex;
        uint16 slippagePosition;
        LibPairsManager.SlippageConfig slippageConfig;

        uint16 feeConfigIndex;
        uint16 feePosition;
        LibFeeManager.FeeConfig feeConfig;

        uint40 longHoldingFeeRate;    // 1e12
        uint40 shortHoldingFeeRate;   // 1e12
    }

    struct PairMaxOiAndFundingFeeConfig {
        uint256 maxLongOiUsd;
        uint256 maxShortOiUsd;
        uint256 fundingFeePerBlockP;
        uint256 minFundingFeeR;
        uint256 maxFundingFeeR;
    }

    struct LeverageMargin {
        uint256 notionalUsd;
        uint16 maxLeverage;
        uint16 initialLostP; // 1e4
        uint16 liqLostP;     // 1e4
    }

    struct FeeConfig {
        uint16 openFeeP;     // 1e4
        uint16 closeFeeP;    // 1e4
        uint24 shareP;       // 1e5
        uint24 minCloseFeeP; // 1e5
    }

    struct TradingPair {
        // BTC address
        address base;
        string name;
        PairType pairType;
        PairStatus status;
        PairMaxOiAndFundingFeeConfig pairConfig;
        LeverageMargin[] leverageMargins;
        ISlippageManager.SlippageConfig slippageConfig;
        FeeConfig feeConfig;
    }

    struct UpdatePairMaxOiParam {
        address base;
        uint256 maxLongOiUsd;
        uint256 maxShortOiUsd;
    }

    function addPair(
        address base, string calldata name,
        PairType pairType, PairStatus status,
        PairMaxOiAndFundingFeeConfig calldata pairConfig,
        uint16 slippageConfigIndex, uint16 feeConfigIndex,
        LibPairsManager.LeverageMargin[] calldata leverageMargins,
        uint40 longHoldingFeeRate, uint40 shortHoldingFeeRate
    ) external;

    function updatePairMaxOi(address base, uint256 maxLongOiUsd, uint256 maxShortOiUsd) external;

    function batchUpdatePairMaxOi(UpdatePairMaxOiParam[] calldata params) external;

    function updatePairHoldingFeeRate(address base, uint40 longHoldingFeeRate, uint40 shortHoldingFeeRate) external;

    function updatePairFundingFeeConfig(
        address base, uint256 fundingFeePerBlockP, uint256 minFundingFeeR, uint256 maxFundingFeeR
    ) external;

    function removePair(address base) external;

    function updatePairStatus(address base, PairStatus status) external;

    function batchUpdatePairStatus(PairType pairType, PairStatus status) external;

    function updatePairSlippage(address base, uint16 slippageConfigIndex) external;

    function updatePairFee(address base, uint16 feeConfigIndex) external;

    function updatePairLeverageMargin(address base, LibPairsManager.LeverageMargin[] calldata leverageMargins) external;

    function pairsV3() external view returns (PairView[] memory);

    function getPairByBaseV3(address base) external view returns (PairView memory);

    function getPairForTrading(address base) external view returns (TradingPair memory);

    function getPairConfig(address base) external view returns (PairMaxOiAndFundingFeeConfig memory);

    function getPairFeeConfig(address base) external view returns (FeeConfig memory);

    function getPairHoldingFeeRate(address base, bool isLong) external view returns (uint40 holdingFeeRate);

    function getPairSlippageConfig(address base) external view returns (ISlippageManager.SlippageConfig memory);
}
