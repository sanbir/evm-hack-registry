// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./ITradingPortal.sol";
import "./ITradingClose.sol";

/*
|-----------> 8 bit <-----------|
|---|---|---|---|---|---|---|---|
|   |   |   |   |   |   | 1 | 0 |
|---|---|---|---|---|---|---|---|
*/
enum FeatureSwitches {
    AS_MARGIN,
    AS_BET
}

interface IVault {

    event CloseTradeRemoveLiquidity(address indexed token, uint256 amount);

    struct Token {
        address tokenAddress;
        uint16 weight;
        uint16 feeBasisPoints;
        uint16 taxBasisPoints;
        bool stable;
        bool dynamicFee;
        bool asMargin;
        bool asBet;
    }

    struct LpItem {
        address tokenAddress;
        int256 value;
        uint8 decimals;
        int256 valueUsd; // decimals = 18
        uint16 targetWeight;
        uint16 feeBasisPoints;
        uint16 taxBasisPoints;
        bool dynamicFee;
    }

    struct MarginToken {
        address token;
        bool switchOn;
        uint8 decimals;
        uint256 price;
    }

    function addToken(
        address tokenAddress, uint16 feeBasisPoints, uint16 taxBasisPoints,
        bool stable, bool dynamicFee, bool asMargin, bool asBet, uint16[] calldata weights
    ) external;

    function removeToken(address tokenAddress, uint16[] calldata weights) external;

    function updateToken(address tokenAddress, uint16 feeBasisPoints, uint16 taxBasisPoints, bool dynamicFee) external;

    function updateTokenFeature(address tokenAddress, bool asMargin, bool asBet) external;

    function changeWeight(uint16[] calldata weights) external;

    function setSecurityMarginP(uint16 _securityMarginP) external;

    function securityMarginP() external view returns (uint16);

    function tokensV3() external view returns (Token[] memory);

    function getTokenByAddress(address tokenAddress) external view returns (Token memory);

    function getTokenForTrading(address tokenAddress) external view returns (MarginToken memory);

    function getTokenForPrediction(address tokenAddress) external view returns (MarginToken memory);

    function itemValue(address token) external view returns (LpItem memory lpItem);

    function totalValue() external view returns (LpItem[] memory lpItems);

    function increase(address token, uint256 amounts) external;

    function decreaseByCloseTrade(address token, uint256 amount) external returns (ITradingClose.SettleToken[] memory);

    function decrease(address token, uint256 amount) external;

    function maxWithdrawAbleUsd() external view returns (int256);
}
