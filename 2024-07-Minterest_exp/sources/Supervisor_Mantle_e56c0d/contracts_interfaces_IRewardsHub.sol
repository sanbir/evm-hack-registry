// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.17;

import "./IRewardsHubLight.sol";

interface IRewardsHub is IRewardsHubLight {
    event RewardUnlocked(address account, uint256 amount);

    /**
     * @notice Gets summary amount of available and delayed balances of an account.
     */
    function totalBalanceOf(address account) external view override returns (uint256);

    /**
     * @notice Gets part of delayed rewards that is unlocked and have become available.
     */
    function getUnlockableRewards(address account) external view returns (uint256);
}
