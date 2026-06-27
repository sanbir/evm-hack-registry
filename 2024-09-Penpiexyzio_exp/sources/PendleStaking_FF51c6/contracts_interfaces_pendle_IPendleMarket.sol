// SPDX-License-Identifier: MIT
pragma solidity =0.8.19;

import "./IPPrincipalToken.sol";
import "./IStandardizedYield.sol";
import "./IPYieldToken.sol";

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";


interface IPendleMarket is IERC20Metadata {

    function readTokens() external view returns (
        IStandardizedYield _SY,
        IPPrincipalToken _PT,
        IPYieldToken _YT
    );

    function rewardState(address _rewardToken) external view returns (
        uint128 index,
        uint128 lastBalance
    );

    function userReward(address token, address user) external view returns (
        uint128 index, uint128 accrued
    );

    function redeemRewards(address user) external returns (uint256[] memory);

    function getRewardTokens() external view returns (address[] memory);
}