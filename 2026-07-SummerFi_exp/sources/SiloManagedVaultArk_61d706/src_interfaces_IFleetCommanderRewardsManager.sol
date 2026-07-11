// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStakingRewardsManagerBase} from "@summerfi/rewards-contracts/interfaces/IStakingRewardsManagerBase.sol";

/**
 * @title IFleetCommanderRewardsManager
 * @notice Interface for the FleetStakingRewardsManager contract
 * @dev Extends IStakingRewardsManagerBase with Fleet-specific functionality
 */
interface IFleetCommanderRewardsManager is IStakingRewardsManagerBase {
    /**
     * @notice Returns the address of the FleetCommander contract
     * @return The address of the FleetCommander
     */
    function fleetCommander() external view returns (address);

    /**
     * @notice Thrown when a non-AdmiralsQuarters contract tries
     * to unstake on behalf
     */
    error CallerNotAdmiralsQuarters();

    /**
     * @notice Thrown when AdmiralsQuarters tries to unstake for
     * someone other than msg.sender
     */
    error InvalidUnstakeRecipient();

    /* @notice Thrown when trying to add a staking token as a reward token */
    error CantAddStakingTokenAsReward();
}
