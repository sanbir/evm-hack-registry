// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICvgRewards {
    function cvgCycleRewards() external view returns (uint256);

    function addGauge(address gaugeAddress) external;

    function removeGauge(address gaugeAddress) external;

    function getCycleLocking(uint256 timestamp) external view returns (uint256);
}
