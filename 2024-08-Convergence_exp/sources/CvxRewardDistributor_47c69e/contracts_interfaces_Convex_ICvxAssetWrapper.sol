// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
interface ICvxAssetWrapper is IERC20Metadata {
    struct ConvexAssetRewardData {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    function stake(uint256 amount, address to) external;

    function stake(uint256 amount) external;

    function stakeFor(address _to, uint256 _amount) external;

    function withdraw(uint256 amount) external;

    function setRewardWeight(uint256 weight) external;

    function getReward(address account) external;

    function rewardData(address token) external view returns (ConvexAssetRewardData memory);

    function rewardTokenLength() external view returns (uint256);

    function rewardTokens(uint256 id) external view returns (address);
}
