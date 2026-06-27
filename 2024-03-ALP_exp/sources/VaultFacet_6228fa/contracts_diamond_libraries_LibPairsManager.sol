// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./LibFeeManager.sol";
import "../interfaces/IPriceFacade.sol";
import "../interfaces/ITradingCore.sol";
import "../interfaces/IPairsManager.sol";
import "../interfaces/ISlippageManager.sol";
import {ZERO, ONE, UC, uc, into} from "unchecked-counter/src/UC.sol";

library LibPairsManager {

    bytes32 constant PAIRS_MANAGER_STORAGE_POSITION = keccak256("apollox.pairs.manager.storage");

    /*
       tier    notionalUsd     maxLeverage      initialLostP        liqLostP
        1      (0 ~ 10,000]        20              95%                97.5%
        2    (10,000 ~ 50,000]     10              90%                 95%
        3    (50,000 ~ 100,000]     5              80%                 90%
        4    (100,000 ~ 200,000]    3              75%                 85%
        5    (200,000 ~ 500,000]    2              60%                 75%
        6    (500,000 ~ 800,000]    1              40%                 50%
    */
    struct LeverageMargin {
        uint256 notionalUsd;
        uint16 tier;
        uint16 maxLeverage;
        uint16 initialLostP; // 1e4
        uint16 liqLostP;     // 1e4
    }

    struct SlippageConfig {
        string name;
        uint256 onePercentDepthAboveUsd;
        uint256 onePercentDepthBelowUsd;
        uint16 slippageLongP;       // 1e4
        uint16 slippageShortP;      // 1e4
        uint16 index;
        ISlippageManager.SlippageType slippageType;
        bool enable;
    }

    struct Pair {
        // BTC/USD
        string name;
        // BTC address
        address base;
        uint16 basePosition;
        IPairsManager.PairType pairType;
        IPairsManager.PairStatus status;

        uint16 slippageConfigIndex;
        uint16 slippagePosition;

        uint16 feeConfigIndex;
        uint16 feePosition;

        uint256 maxLongOiUsd;
        uint256 maxShortOiUsd;
        uint256 fundingFeePerBlockP;  // 1e18
        uint256 minFundingFeeR;       // 1e18
        uint256 maxFundingFeeR;       // 1e18
        // tier => LeverageMargin
        mapping(uint16 => LeverageMargin) leverageMargins;
        uint16 maxTier;

        uint40 longHoldingFeeRate;    // 1e12
        uint40 shortHoldingFeeRate;   // 1e12
    }

    struct PairsManagerStorage {
        // 0/1/2/3/.../ => SlippageConfig
        mapping(uint16 => SlippageConfig) slippageConfigs;
        // SlippageConfig index => pairs.base[]
        mapping(uint16 => address[]) slippageConfigPairs;
        mapping(address => Pair) pairs;
        address[] pairBases;
    }

    function pairsManagerStorage() internal pure returns (PairsManagerStorage storage pms) {
        bytes32 position = PAIRS_MANAGER_STORAGE_POSITION;
        assembly {
            pms.slot := position
        }
    }

    event AddPair(
        address indexed base,
        IPairsManager.PairType indexed pairType, IPairsManager.PairStatus indexed status,
        uint16 slippageConfigIndex, uint16 feeConfigIndex,
        string name, LeverageMargin[] leverageMargins
    );
    event UpdatePairMaxOi(
        address indexed base,
        uint256 oldMaxLongOiUsd, uint256 oldMaxShortOiUsd,
        uint256 maxLongOiUsd, uint256 maxShortOiUsd
    );
    event UpdatePairHoldingFeeRate(
        address indexed base,
        uint40 oldLongRate, uint40 oldShortRate,
        uint40 longRate, uint40 shortRate
    );
    event UpdatePairFundingFeeConfig(
        address indexed base,
        uint256 oldFundingFeePerBlockP, uint256 oldMinFundingFeeR, uint256 oldMaxFundingFeeR,
        uint256 fundingFeePerBlockP, uint256 minFundingFeeR, uint256 maxFundingFeeR
    );
    event RemovePair(address indexed base);
    event UpdatePairStatus(
        address indexed base,
        IPairsManager.PairStatus indexed oldStatus,
        IPairsManager.PairStatus indexed status
    );
    event UpdatePairSlippage(address indexed base, uint16 indexed oldSlippageConfigIndexed, uint16 indexed slippageConfigIndex);
    event UpdatePairFee(address indexed base, uint16 indexed oldFeeConfigIndex, uint16 indexed feeConfigIndex);
    event UpdatePairLeverageMargin(address indexed base, LeverageMargin[] leverageMargins);

    function addPair(
        IPairsManager.PairSimple memory ps,
        uint16 slippageConfigIndex, uint16 feeConfigIndex,
        LeverageMargin[] calldata leverageMargins
    ) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        require(pms.pairBases.length < 70, "LibPairsManager: Exceed the maximum number");
        Pair storage pair = pms.pairs[ps.base];
        require(pair.base == address(0), "LibPairsManager: Pair already exists");
        require(IPriceFacade(address(this)).getPrice(ps.base) > 0, "LibPairsManager: No price feed has been configured for the pair");
        {
            SlippageConfig memory slippageConfig = pms.slippageConfigs[slippageConfigIndex];
            require(slippageConfig.enable, "LibPairsManager: Slippage configuration is not available");
            (LibFeeManager.FeeConfig memory feeConfig, address[] storage feePairs) = LibFeeManager.getFeeConfigByIndex(feeConfigIndex);
            require(feeConfig.enable, "LibPairsManager: Fee configuration is not available");

            pair.slippageConfigIndex = slippageConfigIndex;
            address[] storage slippagePairs = pms.slippageConfigPairs[slippageConfigIndex];
            pair.slippagePosition = uint16(slippagePairs.length);
            slippagePairs.push(ps.base);

            pair.feeConfigIndex = feeConfigIndex;
            pair.feePosition = uint16(feePairs.length);
            feePairs.push(ps.base);
        }
        pair.name = ps.name;
        pair.base = ps.base;
        pair.basePosition = uint16(pms.pairBases.length);
        pms.pairBases.push(ps.base);
        pair.pairType = ps.pairType;
        pair.status = ps.status;
        pair.maxTier = uint16(leverageMargins.length);
        for (UC i = ONE; i <= uc(leverageMargins.length); i = i + ONE) {
            pair.leverageMargins[uint16(i.into())] = leverageMargins[uint16(i.into() - 1)];
        }
        emit AddPair(ps.base, ps.pairType, ps.status, slippageConfigIndex, feeConfigIndex, ps.name, leverageMargins);
    }

    function updatePairMaxOi(address base, uint256 maxLongOiUsd, uint256 maxShortOiUsd) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");

        uint256 oldMaxLongOiUsd = pair.maxLongOiUsd;
        uint256 oldMaxShortOiUsd = pair.maxShortOiUsd;
        pair.maxLongOiUsd = maxLongOiUsd;
        pair.maxShortOiUsd = maxShortOiUsd;
        emit UpdatePairMaxOi(base, oldMaxLongOiUsd, oldMaxShortOiUsd, maxLongOiUsd, maxShortOiUsd);
    }

    function updatePairFundingFeeConfig(address base, uint256 fundingFeePerBlockP, uint256 minFundingFeeR, uint256 maxFundingFeeR) internal {
        require(maxFundingFeeR > minFundingFeeR, "LibPairsManager: fundingFee parameter is invalid");
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");

        ITradingCore(address(this)).updatePairPositionInfo(base);

        uint256 oldFundingFeePerBlockP = pair.fundingFeePerBlockP;
        uint256 oldMinFundingFeeR = pair.minFundingFeeR;
        uint256 oldMaxFundingFeeR = pair.maxFundingFeeR;
        pair.fundingFeePerBlockP = fundingFeePerBlockP;
        pair.minFundingFeeR = minFundingFeeR;
        pair.maxFundingFeeR = maxFundingFeeR;
        emit UpdatePairFundingFeeConfig(
            base, oldFundingFeePerBlockP, oldMinFundingFeeR, oldMaxFundingFeeR,
            fundingFeePerBlockP, minFundingFeeR, maxFundingFeeR
        );
    }

    function updatePairHoldingFeeRate(address base, uint40 longHoldingFeeRate, uint40 shortHoldingFeeRate) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");

        uint40 oldLongRate = pair.longHoldingFeeRate;
        uint40 oldShortRate = pair.shortHoldingFeeRate;
        pair.longHoldingFeeRate = longHoldingFeeRate;
        pair.shortHoldingFeeRate = shortHoldingFeeRate;
        emit UpdatePairHoldingFeeRate(base, oldLongRate, oldShortRate, longHoldingFeeRate, shortHoldingFeeRate);
    }

    function removePair(address base) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");

        ITradingCore.PairQty memory pairQty = ITradingCore(address(this)).getPairQty(base);
        require(pairQty.longQty == 0 && pairQty.shortQty == 0, "LibPairsManager: Position is not 0");

        address[] storage slippagePairs = pms.slippageConfigPairs[pair.slippageConfigIndex];
        uint lastPositionSlippage = slippagePairs.length - 1;
        uint slippagePosition = pair.slippagePosition;
        if (slippagePosition != lastPositionSlippage) {
            address lastBase = slippagePairs[lastPositionSlippage];
            slippagePairs[slippagePosition] = lastBase;
            pms.pairs[lastBase].slippagePosition = uint16(slippagePosition);
        }
        slippagePairs.pop();

        (, address[] storage feePairs) = LibFeeManager.getFeeConfigByIndex(pair.feeConfigIndex);
        uint lastPositionFee = feePairs.length - 1;
        uint feePosition = pair.feePosition;
        if (feePosition != lastPositionFee) {
            address lastBase = feePairs[lastPositionFee];
            feePairs[feePosition] = lastBase;
            pms.pairs[lastBase].feePosition = uint16(feePosition);
        }
        feePairs.pop();

        address[] storage pairBases = pms.pairBases;
        uint lastPositionBase = pairBases.length - 1;
        uint basePosition = pair.basePosition;
        if (basePosition != lastPositionBase) {
            address lastBase = pairBases[lastPositionBase];
            pairBases[basePosition] = lastBase;
            pms.pairs[lastBase].basePosition = uint16(basePosition);
        }
        pairBases.pop();
        // Removing a pair does not delete the leverageMargins mapping data from the Pair struct.
        // If the pair is added again, a new leverageMargins value will be set during the addition,
        // which will overwrite the previous old value.
        delete pms.pairs[base];
        emit RemovePair(base);
    }

    function updatePairStatus(address base, IPairsManager.PairStatus status) internal {
        Pair storage pair = pairsManagerStorage().pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");
        require(pair.status != status, "LibPairsManager: No change in status, no modification required");
        IPairsManager.PairStatus oldStatus = pair.status;
        pair.status = status;
        emit UpdatePairStatus(base, oldStatus, status);
    }

    function batchUpdatePairStatus(IPairsManager.PairType pairType, IPairsManager.PairStatus status) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        address[] memory pairBases = pms.pairBases;
        for (UC i = ZERO; i < uc(pairBases.length); i = i + ONE) {
            Pair storage pair = pms.pairs[pairBases[i.into()]];
            if (pair.pairType == pairType) {
                IPairsManager.PairStatus oldStatus = pair.status;
                pair.status = status;
                emit UpdatePairStatus(pair.base, oldStatus, status);
            }
        }
    }

    function updatePairSlippage(address base, uint16 slippageConfigIndex) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");
        SlippageConfig memory config = pms.slippageConfigs[slippageConfigIndex];
        require(config.enable, "LibPairsManager: Slippage configuration is not available");

        uint16 oldSlippageConfigIndex = pair.slippageConfigIndex;
        address[] storage oldSlippagePairs = pms.slippageConfigPairs[oldSlippageConfigIndex];
        uint lastPositionSlippage = oldSlippagePairs.length - 1;
        uint oldSlippagePosition = pair.slippagePosition;
        if (oldSlippagePosition != lastPositionSlippage) {
            pms.pairs[oldSlippagePairs[lastPositionSlippage]].slippagePosition = uint16(oldSlippagePosition);
            oldSlippagePairs[oldSlippagePosition] = oldSlippagePairs[lastPositionSlippage];
        }
        oldSlippagePairs.pop();

        pair.slippageConfigIndex = slippageConfigIndex;
        address[] storage slippagePairs = pms.slippageConfigPairs[slippageConfigIndex];
        pair.slippagePosition = uint16(slippagePairs.length);
        slippagePairs.push(base);
        emit UpdatePairSlippage(base, oldSlippageConfigIndex, slippageConfigIndex);
    }

    function updatePairFee(address base, uint16 feeConfigIndex) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");
        (LibFeeManager.FeeConfig memory feeConfig, address[] storage feePairs) = LibFeeManager.getFeeConfigByIndex(feeConfigIndex);
        require(feeConfig.enable, "LibPairsManager: Fee configuration is not available");

        uint16 oldFeeConfigIndex = pair.feeConfigIndex;
        (, address[] storage oldFeePairs) = LibFeeManager.getFeeConfigByIndex(oldFeeConfigIndex);
        uint lastPositionFee = oldFeePairs.length - 1;
        uint oldFeePosition = pair.feePosition;
        if (oldFeePosition != lastPositionFee) {
            pms.pairs[oldFeePairs[lastPositionFee]].feePosition = uint16(oldFeePosition);
            oldFeePairs[oldFeePosition] = oldFeePairs[lastPositionFee];
        }
        oldFeePairs.pop();

        pair.feeConfigIndex = feeConfigIndex;
        pair.feePosition = uint16(feePairs.length);
        feePairs.push(base);
        emit UpdatePairFee(base, oldFeeConfigIndex, feeConfigIndex);
    }

    function updatePairLeverageMargin(address base, LeverageMargin[] calldata leverageMargins) internal {
        PairsManagerStorage storage pms = pairsManagerStorage();
        Pair storage pair = pms.pairs[base];
        require(pair.base != address(0), "LibPairsManager: Pair does not exist");

        uint maxTier = pair.maxTier > leverageMargins.length ? pair.maxTier : leverageMargins.length;
        for (UC i = ONE; i <= uc(maxTier); i = i + ONE) {
            if (i <= uc(leverageMargins.length)) {
                pair.leverageMargins[uint16(i.into())] = leverageMargins[uint16(i.into() - 1)];
            } else {
                delete pair.leverageMargins[uint16(i.into())];
            }
        }
        pair.maxTier = uint16(leverageMargins.length);
        emit UpdatePairLeverageMargin(base, leverageMargins);
    }
}
