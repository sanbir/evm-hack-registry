// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

library Constants {
    uint256 private constant MAX = ~uint256(0);
    uint256 private constant _launchSupply = 1 * 10**6 * 10**9;
    uint256 private constant _largeTotal = (MAX - (MAX % _launchSupply));

    uint256 private constant _deployerCost = 5 ether;

    uint256 private constant _baseExpansionFactor = 100;
    uint256 private constant _baseContractionFactor = 100;
    uint256 private constant _incentivePot = 50;
    uint256 private constant _baseUtilityFee = 50;
    uint256 private constant _baseContractionCap = 1000;

    uint256 private constant _stabilizerFee = 250;
    uint256 private constant _stabilizationLowerBound = 50;
    uint256 private constant _stabilizationLowerReset = 75;
    uint256 private constant _stabilizationUpperBound = 150;
    uint256 private constant _stabilizationUpperReset = 125;
    uint256 private constant _stabilizePercent = 10;

    uint256 private constant _treasuryFee = 250;

    uint256 private constant _presaleIndividualCap = 1 ether;
    uint256 private constant _presaleCap = 1 * 10**5 * 10**9;
    uint256 private constant _maxPresaleGas = 200000000000;

    uint256 private constant _epochLength = 4 hours;

    uint256 private constant _liquidityReward = 25 * 10**9;
    uint256 private constant _minForLiquidity = 500 * 10**9;
    uint256 private constant _minForCallerLiquidity = 500 * 10**9;

    address private constant _routerAddress = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private constant _factoryAddress = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address payable private constant _deployerAddress = 0xCEe3101c0A8167f083F34B95A2f243c9b0BEF6a6;
    address private constant _treasuryAddress = 0x3363Defd7447f14b7f696c0843AA96516Bc04808;

    string private constant _name = "XSTABLE.PROTOCOL";
    string private constant _symbol = "XST";
    uint8 private constant _decimals = 9;

    /****** Getters *******/
    function getLaunchSupply() internal pure returns (uint256) {
        return _launchSupply;
    }
    function getLargeTotal() internal pure returns (uint256) {
        return _largeTotal;
    }
    function getDeployerCost() internal pure returns (uint256) {
        return _deployerCost;
    }
    function getPresaleCap() internal pure returns (uint256) {
        return _presaleCap;
    }
    function getPresaleIndividualCap() internal pure returns (uint256) {
        return _presaleIndividualCap;
    }
    function getMaxPresaleGas() internal pure returns (uint256) {
        return _maxPresaleGas;
    }
    function getBaseExpansionFactor() internal pure returns (uint256) {
        return _baseExpansionFactor;
    }
    function getBaseContractionFactor() internal pure returns (uint256) {
        return _baseContractionFactor;
    }
    function getIncentivePot() internal pure returns (uint256) {
        return _incentivePot;
    }
    function getBaseContractionCap() internal pure returns (uint256) {
        return _baseContractionCap;
    }
    function getBaseUtilityFee() internal pure returns (uint256) {
        return _baseUtilityFee;
    }
    function getStabilizerFee() internal pure returns (uint256) {
        return _stabilizerFee;
    }
    function getStabilizationLowerBound() internal pure returns (uint256) {
        return _stabilizationLowerBound;
    }
    function getStabilizationLowerReset() internal pure returns (uint256) {
        return _stabilizationLowerReset;
    }
    function getStabilizationUpperBound() internal pure returns (uint256) {
        return _stabilizationUpperBound;
    }
    function getStabilizationUpperReset() internal pure returns (uint256) {
        return _stabilizationUpperReset;
    }
    function getStabilizePercent() internal pure returns (uint256) {
        return _stabilizePercent;
    }
    function getTreasuryFee() internal pure returns (uint256) {
        return _treasuryFee;
    }
    function getEpochLength() internal pure returns (uint256) {
        return _epochLength;
    }
    function getLiquidityReward() internal pure returns (uint256) {
        return _liquidityReward;
    }
    function getMinForLiquidity() internal pure returns (uint256) {
        return _minForLiquidity;
    }
    function getMinForCallerLiquidity() internal pure returns (uint256) {
        return _minForCallerLiquidity;
    }
    function getRouterAdd() internal pure returns (address) {
        return _routerAddress;
    }
    function getFactoryAdd() internal pure returns (address) {
        return _factoryAddress;
    }
    function getDeployerAdd() internal pure returns (address payable) {
        return _deployerAddress;
    }
    function getTreasuryAdd() internal pure returns (address) {
        return _treasuryAddress;
    }
    function getName() internal pure returns (string memory)  {
        return _name;
    }
    function getSymbol() internal pure returns (string memory) {
        return _symbol;
    }
    function getDecimals() internal pure returns (uint8) {
        return _decimals;
    }
}