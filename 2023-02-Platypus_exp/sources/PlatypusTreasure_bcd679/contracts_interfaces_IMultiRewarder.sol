// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IMultiRewarder {
    function onPtpReward(
        address _user,
        uint256 _lpAmount,
        uint256 _newLpAmount
    ) external returns (uint256[] memory rewards);

    function pendingTokens(address _user, uint256 _lpAmount) external view returns (uint256[] memory rewards);

    function rewardTokens() external view returns (IERC20[] memory tokens);

    function poolLength() external view returns (uint256);
}
