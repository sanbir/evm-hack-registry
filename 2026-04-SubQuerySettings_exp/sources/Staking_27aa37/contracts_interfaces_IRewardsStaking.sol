// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

interface IRewardsStaking {
    function onStakeChange(address indexer, address user) external;

    function onICRChange(address indexer, uint256 startEra) external;

    function applyStakeChange(address indexer, address staker) external;

    function applyICRChange(address indexer) external;

    function checkAndReflectSettlement(
        address indexer,
        uint256 lastClaimEra
    ) external returns (bool);

    function getTotalStakingAmount(address _indexer) external view returns (uint256);

    function getLastSettledEra(address indexer) external view returns (uint256);

    function getDelegationAmount(address source, address indexer) external view returns (uint256);

    function applyRunnerWeightChange(address _runner) external;

    function applyRedelegation(address runner, address staker) external;
}
