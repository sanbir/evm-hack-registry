// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

interface IReferralLiquidTokenStakingPool {
    /**
     * Events
     */
    event ReferralCode(bytes32 indexed code);

    /**
     * Methods
     */
    function stakeBondsWithCode(bytes32 code) external payable;

    function stakeCertsWithCode(bytes32 code) external payable;
}
