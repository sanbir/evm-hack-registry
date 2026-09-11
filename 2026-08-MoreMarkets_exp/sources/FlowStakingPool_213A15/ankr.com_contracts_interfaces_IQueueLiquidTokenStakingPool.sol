// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

interface IQueueLiquidTokenStakingPool {
    /**
     * Events
     */
    event PendingUnstake(
        address indexed ownerAddress,
        address indexed receiverAddress,
        uint256 amount
    );

    event RewardsDistributed(address[] claimers, uint256[] amounts);

    event ManualDistributeExpected(
        address indexed claimer,
        uint256 amount,
        uint256 indexed id
    );

    event DistributeGasLimitChanged(uint256 prevValue, uint256 newValue);
}
