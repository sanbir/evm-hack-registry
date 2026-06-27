// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICvgRewards {
    struct CvgAprStruct {
        GaugeView[] gaugeData;
        uint256 totalWeight;
    }

    struct GaugeView {
        string symbol;
        address stakingAddress;
        uint256 weight;
        uint256 typeWeight;
        int128 gaugeType;
    }

    function cvgCycleRewards() external view returns (uint256);

    function addGauge(address gaugeAddress) external;

    function removeGauge(address gaugeAddress) external;

    function getCycleLocking(uint256 timestamp) external view returns (uint256);

    function writeStakingRewards(uint256 stepAmount) external;

    function getGaugeChunk(uint256 from, uint256 to) external view returns (GaugeView[] memory);

    function gaugesLength() external view returns (uint256);
}
