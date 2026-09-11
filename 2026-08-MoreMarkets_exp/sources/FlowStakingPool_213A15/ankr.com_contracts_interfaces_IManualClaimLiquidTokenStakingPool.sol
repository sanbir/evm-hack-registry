// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

interface IManualClaimLiquidTokenStakingPool {
    /**
     * Events
     */
    event RewardsClaimed(
        address indexed receiverAddress,
        address claimer,
        uint256 amount
    );

    event ManualClaimExpected(address indexed claimer, uint256 amount);
}
