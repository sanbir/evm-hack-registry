// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

interface ITreasury {
    function collateralReserve() external view returns (address);

    function isPool(address _address) external view returns (bool);

    function isMintingPool(address _poolAddress, address _dToken) external view returns (bool);

    function epoch() external view returns (uint256);

    function nextEpochTimestamp() external view returns (uint256);

    function epochInfo()
        external
        view
        returns (
            uint256 _epoch,
            uint256 lastEpochTimestamp,
            uint256 epochDuration
        );

    function utilizationRatio(address foundry) external view returns (uint256);

    function requestTransfer(
        address token,
        address receiver,
        uint256 amount
    ) external;

    event PoolAdded(address pool);
    event PoolRemoved(address pool);
    event EpochDurationChanged(uint256 epochDuration);
    event FoundryAdded(address foundry, address pool);
    event FoundryRemoved(address foundry, address pool);
    event UtilizationRatioChanged(address pool, uint256 ratio);
    event CollateralReserveChanged(address collateralReserve);
}
