// SPDX-License-Identifier: SMIT
pragma solidity ^0.8.0;

struct Order {
    uint256 amount; // USDT
    uint256 totalReward; // USDT
    uint256 createdTime;
    uint256 claimedTime;
    uint256 claimedReward; // USDT
    bool running;
}

interface IPoolV2 {
    function getOrder(address) external view returns (Order memory);
}
