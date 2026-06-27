// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../utils/Constants.sol";
import "../interfaces/ITradingOpen.sol";
import "../interfaces/ITradingClose.sol";
import "../interfaces/IPredictUpDown.sol";
import {RequestType} from "../interfaces/IPriceFacade.sol";
import "./LibChainlinkPrice.sol";
import {ZERO, ONE, UC, uc, into} from "unchecked-counter/src/UC.sol";

library LibPriceFacade {

    bytes32 constant PRICE_FACADE_POSITION = keccak256("apollox.price.facade.storage");

    struct LatestCallbackPrice {
        uint64 price;
        uint40 timestamp;
    }

    struct IdInfo {
        bytes32 id;
        RequestType requestType;
    }

    struct PendingPrice {
        uint256 blockNumber;
        address token;
        IdInfo[] ids;
    }

    struct PriceFacadeStorage {
        // BTC/ETH/BNB/.../ =>
        mapping(address => LatestCallbackPrice) callbackPrices;
        // keccak256(token, block.number) =>
        mapping(bytes32 => PendingPrice) pendingPrices;
        uint16 lowPriceGapP;   // 1e4
        uint16 highPriceGapP;  // 1e4
        uint16 maxDelay;
        uint16 triggerLowPriceGapP;   // 1e4
        uint16 triggerHighPriceGapP;  // 1e4
    }

    function priceFacadeStorage() internal pure returns (PriceFacadeStorage storage pfs) {
        bytes32 position = PRICE_FACADE_POSITION;
        assembly {
            pfs.slot := position
        }
    }

    event SetLowPriceGapP(uint16 indexed oldLowPriceGapP, uint16 indexed lowPriceGapP);
    event SetHighPriceGapP(uint16 indexed oldHighPriceGapP, uint16 indexed highPriceGapP);
    event SetTriggerLowPriceGapP(uint16 indexed old, uint16 indexed triggerLowPriceGapP);
    event SetTriggerHighPriceGapP(uint16 indexed old, uint16 indexed triggerHighPriceGapP);
    event SetMaxDelay(uint16 indexed oldMaxDelay, uint16 indexed maxDelay);
    event RequestPrice(bytes32 indexed requestId, address indexed token);
    event PriceRejected(
        address indexed feeder, bytes32 indexed requestId, address indexed token,
        uint64 price, uint64 beforePrice, uint40 updatedAt
    );
    event PriceUpdated(
        address indexed feeder, bytes32 indexed requestId,
        address indexed token, uint64 price
    );

    function initialize(uint16 lowPriceGapP, uint16 highPriceGapP, uint16 maxDelay) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        require(pfs.lowPriceGapP == 0 && pfs.highPriceGapP == 0 && pfs.maxDelay == 0, "LibPriceFacade: Already initialized");
        _setLowPriceGapP(pfs, lowPriceGapP);
        _setHighPriceGapP(pfs, highPriceGapP);
        setMaxDelay(maxDelay);
    }

    function _setLowPriceGapP(PriceFacadeStorage storage pfs, uint16 lowPriceGapP) private {
        uint16 old = pfs.lowPriceGapP;
        pfs.lowPriceGapP = lowPriceGapP;
        emit SetLowPriceGapP(old, lowPriceGapP);
    }

    function _setHighPriceGapP(PriceFacadeStorage storage pfs, uint16 highPriceGapP) private {
        uint16 old = pfs.highPriceGapP;
        pfs.highPriceGapP = highPriceGapP;
        emit SetHighPriceGapP(old, highPriceGapP);
    }

    function setLowAndHighPriceGapP(uint16 lowPriceGapP, uint16 highPriceGapP) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        if (lowPriceGapP > 0 && highPriceGapP > 0) {
            require(highPriceGapP > lowPriceGapP, "LibPriceFacade: highPriceGapP must be greater than lowPriceGapP");
            _setLowPriceGapP(pfs, lowPriceGapP);
            _setHighPriceGapP(pfs, highPriceGapP);
        } else if (lowPriceGapP > 0) {
            require(pfs.highPriceGapP > lowPriceGapP, "LibPriceFacade: highPriceGapP must be greater than lowPriceGapP");
            _setLowPriceGapP(pfs, lowPriceGapP);
        } else {
            require(highPriceGapP > pfs.lowPriceGapP, "LibPriceFacade: highPriceGapP must be greater than lowPriceGapP");
            _setHighPriceGapP(pfs, highPriceGapP);
        }
    }

    function _setTriggerLowPriceGapP(PriceFacadeStorage storage pfs, uint16 triggerLowPriceGapP) private {
        uint16 old = pfs.triggerLowPriceGapP;
        pfs.triggerLowPriceGapP = triggerLowPriceGapP;
        emit SetTriggerLowPriceGapP(old, triggerLowPriceGapP);
    }

    function _setTriggerHighPriceGapP(PriceFacadeStorage storage pfs, uint16 triggerHighPriceGapP) private {
        uint16 old = pfs.triggerHighPriceGapP;
        pfs.triggerHighPriceGapP = triggerHighPriceGapP;
        emit SetTriggerHighPriceGapP(old, triggerHighPriceGapP);
    }

    function setTriggerLowAndHighPriceGapP(uint16 triggerLowPriceGapP, uint16 triggerHighPriceGapP) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        if (triggerLowPriceGapP > 0 && triggerHighPriceGapP > 0) {
            require(triggerHighPriceGapP > triggerLowPriceGapP, "LibPriceFacade: triggerHighPriceGapP must be greater than triggerLowPriceGapP");
            _setTriggerLowPriceGapP(pfs, triggerLowPriceGapP);
            _setTriggerHighPriceGapP(pfs, triggerHighPriceGapP);
        } else if (triggerLowPriceGapP > 0) {
            require(pfs.triggerHighPriceGapP > triggerLowPriceGapP, "LibPriceFacade: triggerHighPriceGapP must be greater than triggerLowPriceGapP");
            _setTriggerLowPriceGapP(pfs, triggerLowPriceGapP);
        } else {
            require(triggerHighPriceGapP > pfs.triggerLowPriceGapP, "LibPriceFacade: triggerHighPriceGapP must be greater than triggerLowPriceGapP");
            _setTriggerHighPriceGapP(pfs, triggerHighPriceGapP);
        }
    }

    function setMaxDelay(uint16 maxDelay) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        uint16 old = pfs.maxDelay;
        pfs.maxDelay = maxDelay;
        emit SetMaxDelay(old, maxDelay);
    }

    function getPrice(address token) internal view returns (uint256) {
        (uint256 price, uint8 decimals,) = LibChainlinkPrice.getPriceFromChainlink(token);
        return decimals == 8 ? price : price * 1e8 / (10 ** decimals);
    }

    function requestPrice(bytes32 id, address token, RequestType requestType) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        bytes32 requestId = keccak256(abi.encode(token, block.number));
        PendingPrice storage pendingPrice = pfs.pendingPrices[requestId];
        require(pendingPrice.ids.length < Constants.MAX_REQUESTS_PER_PAIR_IN_BLOCK, "LibPriceFacade: The requests for price retrieval are too frequent.");
        pendingPrice.ids.push(IdInfo(id, requestType));
        if (pendingPrice.blockNumber != block.number) {
            pendingPrice.token = token;
            pendingPrice.blockNumber = block.number;
            emit RequestPrice(requestId, token);
        }
    }

    function requestPriceCallback(bytes32 requestId, uint64 price) internal {
        PriceFacadeStorage storage pfs = priceFacadeStorage();
        PendingPrice memory pendingPrice = pfs.pendingPrices[requestId];
        IdInfo[] memory ids = pendingPrice.ids;
        require(pendingPrice.blockNumber > 0 && ids.length > 0, "LibPriceFacade: requestId does not exist");

        (uint64 beforePrice, uint40 updatedAt) = getPriceFromCacheOrOracle(pfs, pendingPrice.token);
        uint64 priceGap = price > beforePrice ? price - beforePrice : beforePrice - price;
        uint gapPercentage = priceGap * 1e4 / beforePrice;
        // Excessive price difference. Reject this price
        if (gapPercentage > pfs.highPriceGapP) {
            emit PriceRejected(msg.sender, requestId, pendingPrice.token, price, beforePrice, updatedAt);
            return;
        }
        LatestCallbackPrice storage cachePrice = pfs.callbackPrices[pendingPrice.token];
        cachePrice.timestamp = uint40(block.timestamp);
        cachePrice.price = price;
        // The time interval is too long.
        // receive the current price but not use it
        // and wait for the next price to be fed.
        if (block.timestamp > updatedAt + pfs.maxDelay) {
            emit PriceRejected(msg.sender, requestId, pendingPrice.token, price, beforePrice, updatedAt);
            return;
        }
        uint64 upperPrice = price;
        uint64 lowerPrice = price;
        if (gapPercentage > pfs.lowPriceGapP) {
            (upperPrice, lowerPrice) = price > beforePrice ? (price, beforePrice) : (beforePrice, price);
        }
        for (UC i = ZERO; i < uc(ids.length); i = i + ONE) {
            IdInfo memory idInfo = ids[i.into()];
            if (idInfo.requestType == RequestType.OPEN) {
                try ITradingOpen(address(this)).marketTradeCallback(idInfo.id, upperPrice, lowerPrice) {} catch Error(string memory) {}
            } else if (idInfo.requestType == RequestType.CLOSE) {
                try ITradingClose(address(this)).closeTradeCallback(idInfo.id, upperPrice, lowerPrice) {} catch Error(string memory) {}
            } else {
                try IPredictUpDown(address(this)).predictionCallback(idInfo.id, price) {} catch Error(string memory) {}
            }
        }
        // Deleting data can save a little gas
        emit PriceUpdated(msg.sender, requestId, pendingPrice.token, price);
        delete pfs.pendingPrices[requestId];
    }

    function getPriceFromCacheOrOracle(address token) internal view returns (uint64, uint40) {
        return getPriceFromCacheOrOracle(priceFacadeStorage(), token);
    }

    function getPriceFromCacheOrOracle(PriceFacadeStorage storage pfs, address token) internal view returns (uint64, uint40) {
        LatestCallbackPrice memory cachePrice = pfs.callbackPrices[token];
        (uint256 price, uint8 decimals, uint256 oracleUpdatedAt) = LibChainlinkPrice.getPriceFromChainlink(token);
        require(price <= type(uint64).max && price * 1e8 / (10 ** decimals) <= type(uint64).max, "LibPriceFacade: Invalid price");
        uint40 updatedAt = cachePrice.timestamp >= oracleUpdatedAt ? cachePrice.timestamp : uint40(oracleUpdatedAt);
        // Take the newer price
        uint64 tokenPrice = cachePrice.timestamp >= oracleUpdatedAt ? cachePrice.price :
            (decimals == 8 ? uint64(price) : uint64(price * 1e8 / (10 ** decimals)));
        return (tokenPrice, updatedAt);
    }
}
