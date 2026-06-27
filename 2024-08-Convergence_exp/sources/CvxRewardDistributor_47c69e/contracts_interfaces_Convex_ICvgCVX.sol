// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "../ICommonStruct.sol";

import "./ICvxAssetStakerBuffer.sol";

interface ICvgCVX is IERC20 {
    function mintFees() external view returns (uint256);

    function mint(address to, uint256 amount, bool isLock) external returns (uint256);

    function mintFrom(address from, address to, uint256 amount, bool isLock) external returns (uint256);

    function mintCVXRush(
        uint256 tokenId,
        uint128 amountCvx,
        address to,
        address cvgLockReceiver,
        bool isLock
    ) external returns (uint256);

    function cvxToLock() external view returns (uint256);

    function pullRewards(address processor) external returns (ICommonStruct.TokenAmount[] memory);

    function getRewardTokensConfig() external view returns (ICvxAssetStakerBuffer.CvxRewardConfig[] memory);

    function rewardTokensConfigs(uint256 index) external view returns (ICvxAssetStakerBuffer.CvxRewardConfig memory);

    function withdrawableFees(IERC20 token) external view returns (uint256);

    function getCvxRushAmounts(uint256 amountCvx, bool isLock) external view returns (uint256, uint256);
}
