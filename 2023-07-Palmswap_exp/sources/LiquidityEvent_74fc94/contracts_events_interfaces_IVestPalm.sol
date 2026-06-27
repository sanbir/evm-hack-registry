// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {PurchaseInfo} from "./ILiquidityEvent.sol";

struct VestingSchedule {
    bool isDestroyed;
    uint256 index;
    uint256 tier; // 0 for Tier 1
    uint256 depositTime; // Vesting started timestamp
    uint256 claimed; // Claimed PALM rewards
    uint256 notClaimed; // Not claimed PALM rewards
    uint256 allocated; // Vested PALM rewards
}

interface IVestPalm {
    function deposit(address _account, PurchaseInfo[] calldata pInfo) external;

    function resetUserReward(
        address _account,
        uint256[] calldata _tiers,
        uint256 _length
    ) external;

    function previewRewardsDestroy(
        address _account,
        uint256[] calldata _tiers,
        uint256 _length
    )
        external
        view
        returns (VestingSchedule[] memory schedules, uint256 length);
}
