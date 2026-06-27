// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./IVaultUtils.sol";

interface IVault {
    function isInitialized() external view returns (bool);

    function isLeverageEnabled() external view returns (bool);

    function setVaultUtils(IVaultUtils _vaultUtils) external;

    function setError(uint256 _errorCode, string calldata _error) external;

    function router() external view returns (address);

    function usdp() external view returns (address);

    function collateralToken() external view returns (address);

    function gov() external view returns (address);

    function whitelistedTokenCount() external view returns (uint256);

    function maxLeverage() external view returns (uint256);

    function minProfitTime() external view returns (uint256);

    function hasDynamicFees() external view returns (bool);

    function fundingInterval() external view returns (uint256);

    function getTargetUsdpAmount() external view returns (uint256);

    function inManagerMode() external view returns (bool);

    function inPrivateLiquidationMode() external view returns (bool);

    function maxGasPrice() external view returns (uint256);

    function approvedRouters(
        address _account,
        address _router
    ) external view returns (bool);

    function isLiquidator(address _account) external view returns (bool);

    function isManager(address _account) external view returns (bool);

    function minProfitBasisPoints(
        address _token
    ) external view returns (uint256);

    function tokenBalances(address _token) external view returns (uint256);

    function lastFundingTimes(
        address _token,
        bool _isLong
    ) external view returns (uint256);

    function estimateUSDPOut(uint256 _amount) external view returns (uint256);

    function estimateTokenIn(
        uint256 _usdpAmount
    ) external view returns (uint256);

    function setMaxLeverage(uint256 _maxLeverage) external;

    function setInManagerMode(bool _inManagerMode) external;

    function setManager(address _manager, bool _isManager) external;

    function setIsLeverageEnabled(bool _isLeverageEnabled) external;

    function setMaxGasPrice(uint256 _maxGasPrice) external;

    function setUsdpAmount(uint256 _amount) external;

    function setMaxGlobalSize(
        address _token,
        uint256 _longAmount,
        uint256 _shortAmount
    ) external;

    function setInPrivateLiquidationMode(
        bool _inPrivateLiquidationMode
    ) external;

    function setLiquidator(address _liquidator, bool _isActive) external;

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor
    ) external;

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external;

    function setMaxUsdpAmounts(uint256 _maxUsdpAmounts) external;

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
    ) external;

    function setPriceFeed(address _priceFeed) external;

    function withdrawFees(address _receiver) external returns (uint256);

    function withdrawTokens(address _receiver) external;

    function directPoolDeposit() external;

    function buyUSDP(address _receiver) external returns (uint256);

    function sellUSDP(address _receiver) external returns (uint256);

    function increasePosition(
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external;

    function decreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external returns (uint256);

    function validateLiquidation(
        address _account,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) external view returns (uint256, uint256);

    function liquidatePosition(
        address _account,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external;

    function tokenToUsdMin(
        address _token,
        uint256 _tokenAmount
    ) external view returns (uint256);

    function priceFeed() external view returns (address);

    function fundingRateFactor() external view returns (uint256);

    function cumulativeFundingRates(
        address _token,
        bool _isLong
    ) external view returns (uint256);

    function getNextFundingRate(
        address _token,
        bool _isLong
    ) external view returns (uint256);

    function getFeeBasisPoints(
        address _token,
        uint256 _usdpDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) external view returns (uint256);

    function liquidationFeeUsd() external view returns (uint256);

    function taxBasisPoints() external view returns (uint256);

    function mintBurnFeeBasisPoints() external view returns (uint256);

    function marginFeeBasisPoints() external view returns (uint256);

    function allWhitelistedTokensLength() external view returns (uint256);

    function allWhitelistedTokens(uint256) external view returns (address);

    function whitelistedTokens(address _token) external view returns (bool);

    function stableTokens(address _token) external view returns (bool);

    function shortableTokens(address _token) external view returns (bool);

    function feeReserve() external view returns (uint256);

    function permanentPoolAmount() external view returns (uint256);

    function globalShortSizes(address _token) external view returns (uint256);

    function globalLongSizes(address _token) external view returns (uint256);

    function globalShortAveragePrices(
        address _token
    ) external view returns (uint256);

    function globalLongAveragePrices(
        address _token
    ) external view returns (uint256);

    function maxGlobalShortSizes(
        address _token
    ) external view returns (uint256);

    function maxGlobalLongSizes(address _token) external view returns (uint256);

    function tokenDecimals(address _token) external view returns (uint256);

    function poolAmount() external view returns (uint256);

    function reservedAmounts(
        address _token,
        bool _isLong
    ) external view returns (uint256);

    function totalReservedAmount() external view returns (uint256);

    function usdpAmount() external view returns (uint256);

    function maxUsdpAmount() external view returns (uint256);

    function getRedemptionAmount(
        uint256 _usdpAmount
    ) external view returns (uint256);

    function getMaxPrice(address _token) external view returns (uint256);

    function getMinPrice(address _token) external view returns (uint256);

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);

    function getPosition(
        address _account,
        address _indexToken,
        bool _isLong
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            uint256
        );
}
