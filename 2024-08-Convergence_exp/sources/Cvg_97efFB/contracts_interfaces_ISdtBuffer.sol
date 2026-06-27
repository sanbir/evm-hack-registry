// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./ICvgControlTower.sol";

import "./ISdAssets.sol";

import "./ICommonStruct.sol";

interface ISdtBuffer {
    function initialize(
        ICvgControlTower _cvgControlTower,
        address _sdAssetStaking,
        ISdAssetGauge _sdGaugeAsset,
        IERC20 _sdt
    ) external;

    function pullRewards(address _processor) external returns (ICommonStruct.TokenAmount[] memory);

    function processorRewardsPercentage() external view returns (uint256);
}
