// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.7.0 <0.8.0;
interface IBenqiCompound {
    function claimReward(uint8 rewardType, address payable holder, address[] memory qiTokens) external;
}