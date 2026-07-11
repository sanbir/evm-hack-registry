// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFleetCommander} from "../interfaces/IFleetCommander.sol";
import {IFleetCommanderRewardsManager} from "../interfaces/IFleetCommanderRewardsManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StakingRewardsManagerBase, EnumerableSet} from "@summerfi/rewards-contracts/contracts/StakingRewardsManagerBase.sol";
import {IStakingRewardsManagerBase} from "@summerfi/rewards-contracts/interfaces/IStakingRewardsManagerBase.sol";
/**
 * @title FleetCommanderRewardsManager
 * @notice Contract for managing staking rewards specific to the Fleet system
 * @dev Extends StakingRewardsManagerBase with Fleet-specific functionality
 */

contract FleetCommanderRewardsManager is
    IFleetCommanderRewardsManager,
    StakingRewardsManagerBase
{
    using EnumerableSet for EnumerableSet.AddressSet;
    address public immutable fleetCommander;

    /**
     * @notice Initializes the FleetStakingRewardsManager contract
     * @param _accessManager Address of the AccessManager contract
     * @param _fleetCommander Address of the FleetCommander contract
     */
    constructor(
        address _accessManager,
        address _fleetCommander
    ) StakingRewardsManagerBase(_accessManager) {
        fleetCommander = _fleetCommander;
        stakingToken = fleetCommander;
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function stakeOnBehalfOf(
        address receiver,
        uint256 amount
    ) external override updateReward(receiver) {
        _stake(_msgSender(), receiver, amount);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function notifyRewardAmount(
        address rewardToken,
        uint256 reward,
        uint256 newRewardsDuration
    )
        external
        override(StakingRewardsManagerBase, IStakingRewardsManagerBase)
        onlyGovernor
        updateReward(address(0))
    {
        if (address(rewardToken) == address(stakingToken)) {
            revert CantAddStakingTokenAsReward();
        }
        _notifyRewardAmount(rewardToken, reward, newRewardsDuration);
    }

    function unstakeAndWithdrawOnBehalfOf(
        address owner,
        uint256 amount,
        bool claimRewards
    ) external override updateReward(owner) {
        // Check if the caller is the same as the 'owner' address or has the required role
        if (_msgSender() != owner && !hasAdmiralsQuartersRole(_msgSender())) {
            revert CallerNotAdmiralsQuarters();
        }

        _unstake(owner, address(this), amount);
        IFleetCommander(fleetCommander).redeem(amount, owner, address(this));

        if (claimRewards) {
            uint256 rewardTokenCount = _rewardTokensList.length();
            for (uint256 i = 0; i < rewardTokenCount; i++) {
                address rewardTokenAddress = _rewardTokensList.at(i);
                _getReward(owner, rewardTokenAddress);
            }
        }
    }
}
