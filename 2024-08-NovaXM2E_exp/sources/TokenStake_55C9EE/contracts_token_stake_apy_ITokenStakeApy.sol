// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface ITokenStakeApy {
    function setNftApy(uint256 _poolId, uint256 _poolIdEarnPerDay) external;

    function setNftApyExactly(uint256 _poolId, uint256[] calldata _startTime, uint256[] calldata _endTime, uint256[] calldata _tokenEarn) external;

    function getStartTime(uint256 _poolId) external view returns (uint256[] memory);

    function getEndTime(uint256 _poolId) external view returns (uint256[] memory);

    function getPoolApy(uint256 _poolId) external view returns (uint256[] memory);

    function getMaxIndex(uint256 _poolId) external view returns (uint256);
}
