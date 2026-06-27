// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./../ICommonStruct.sol";
import "./ICvxAssetWrapper.sol";
import "./ICvxAssetStakingService.sol";

interface ICvxAssetStakerBuffer {
    struct CvxRewardConfig {
        IERC20 token;
        uint48 processorFees;
        uint48 convexTreasury;
    }

    function withdraw(
        uint256 amount,
        ICvxAssetStakingService.OUT_TOKEN_TYPE outTokenType,
        address withdrawer,
        uint256 minAssetOut
    ) external;

    function stakeCvxAsset() external;

    function postStaking(uint256 feeAmount, bool isStake) external;

    function pullRewards(address _processor) external returns (ICommonStruct.TokenAmount[] memory);

    function getRewardTokensConfig() external view returns (ICvxAssetStakerBuffer.CvxRewardConfig[] memory);

    function cvxAssetWrapper() external view returns (ICvxAssetWrapper);

    function rewardTokensConfigs(uint256 index) external view returns (ICvxAssetStakerBuffer.CvxRewardConfig memory);

    function withdrawableFees(IERC20 token) external view returns (uint256);
}
