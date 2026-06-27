// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface IDelegator {

    function getStakedTokenAddressAtWithdrawalsIndex(
        uint256 _index
    ) external returns (address);

    function restake(
        address _stakedTokenAddress,
        address _eigenLayerStrategyManagerAddress,
        address _eigenLayerStrategyAddress
    ) external returns (uint256);

    function queueWithdrawal(
        address _stakedTokenAddress,
        address _eigenLayerStrategyManagerAddress,
        address _eigenLayerStrategyAddress
    ) external returns (uint96);

    function canWithdraw(
        uint96 _withdrawalIndex,
        uint256 _middlewareTimesIndex,
        address _eigenLayerStrategyManagerAddress
    ) external view returns (bool);

    function completeQueuedWithdrawal(
        uint96 _withdrawalIndex,
        uint256 _middlewareTimesIndex,
        address _eigenLayerStrategyManagerAddress,
        address _eigenLayerStrategyAddress
    ) external;

    function pull(address token) external returns (uint256 balance);

    function getAssetBalances(
        address _eigenLayerStrategyManagerAddress
    ) external view returns (address[] memory, uint256[] memory);

    function getAssetBalance(
        address _token,
        address _eigenLayerStrategyAddress
    ) external view returns (uint256);

}