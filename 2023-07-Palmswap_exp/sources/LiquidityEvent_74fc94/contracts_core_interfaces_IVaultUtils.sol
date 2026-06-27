// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IVaultUtils {
    function updateCumulativeFundingRate(address _indexToken)
        external
        returns (bool);

    function validateIncreasePosition(
        address _account,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external view;

    function validateDecreasePosition(
        address _account,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external view;

    function validateLiquidation(
        address _account,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) external view returns (uint256, uint256);

    function getEntryFundingRate(address _indexToken, bool _isLong)
        external
        view
        returns (uint256);

    function getPositionFee(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) external view returns (uint256);

    function getFundingFee(
        address _account,
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) external view returns (uint256);

    function getBuyUsdpFeeBasisPoints(address _token, uint256 _usdpAmount)
        external
        view
        returns (uint256);

    function getSellUsdpFeeBasisPoints(address _token, uint256 _usdpAmount)
        external
        view
        returns (uint256);

    function getFeeBasisPoints(
        address _token,
        uint256 _usdpDelta,
        uint256 _feeBasisPoints,
        uint256 _taxBasisPoints,
        bool _increment
    ) external view returns (uint256);
}
