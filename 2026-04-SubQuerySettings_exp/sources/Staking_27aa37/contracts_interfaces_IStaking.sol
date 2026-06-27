// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.15;

/**
 * @dev Total staking amount information. One per Indexer.
 * Stake amount change need to be applied at next Era.
 */
struct StakingAmount {
    uint256 era; // last update era
    uint256 valueAt; // value at the era
    uint256 valueAfter; // value to be refreshed from next era
}

/**
 * @dev Unbond amount information. One per request per Delegator.
 * Delegator can withdraw the unbond amount after the lockPeriod.
 */
struct UnbondAmount {
    address indexer; // the indexer before delegate.
    uint256 amount; // pending unbonding amount
    uint256 startTime; // unbond start time
}

enum UnbondType {
    Undelegation,
    Unstake,
    Commission,
    Merge
}

/**
 * @dev Instant delegation quota tracking. One per Delegator.
 * Tracks quota usage within current era, auto-resets on era change.
 */
struct InstantQuotaUsage {
    uint256 era; // era of quota usage
    uint256 amount; // quota used in this era
}

interface IStaking {
    function lockedAmount(address _delegator) external view returns (uint256);

    function unbondCommission(address _runner, uint256 _amount) external;

    function addDelegation(
        address _source,
        address _runner,
        uint256 _amount,
        bool instant
    ) external;

    function transferDelegationTokens(address _source, uint256 _amount) external;

    function updateInstantQuotaUsed(address delegator, uint256 era, uint256 amount) external;

    function setInstantDelegationParams(uint256 _perEraQuota, uint256 _windowPercent) external;

    function getInstantQuotaRemaining(
        address delegator,
        uint256 era
    ) external view returns (uint256);

    function instantDelegationQuota() external view returns (uint256);

    function instantEraWindowPercent() external view returns (uint256);
}
