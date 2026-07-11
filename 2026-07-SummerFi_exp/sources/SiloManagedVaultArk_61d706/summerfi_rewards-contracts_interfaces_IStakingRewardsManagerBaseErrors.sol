// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/* @title IStakingRewardsManagerBaseErrors
 * @notice Interface defining custom errors for the Staking Rewards Manager
 */
interface IStakingRewardsManagerBaseErrors {
    /* @notice Thrown when attempting to stake zero tokens */
    error CannotStakeZero();

    /* @notice Thrown when attempting to withdraw zero tokens */
    error CannotWithdrawZero();

    /* @notice Thrown when the provided reward amount is too high */
    error ProvidedRewardTooHigh();

    /* @notice Thrown when trying to set rewards before the current period is complete */
    error RewardPeriodNotComplete();

    /* @notice Thrown when there are no reward tokens set */
    error NoRewardTokens();

    /* @notice Thrown when trying to add a reward token that already exists */
    error RewardTokenAlreadyExists();

    /* @notice Thrown when setting an invalid rewards duration */
    error InvalidRewardsDuration();

    /* @notice Thrown when trying to interact with a reward token that hasn't been initialized */
    error RewardTokenNotInitialized();

    /* @notice Thrown when the reward amount is invalid for the given duration
     * @param rewardToken The address of the reward token
     * @param rewardsDuration The duration for which the reward is invalid
     */
    error InvalidRewardAmount(address rewardToken, uint256 rewardsDuration);

    /* @notice Thrown when trying to interact with the staking token before it's initialized */
    error StakingTokenNotInitialized();

    /* @notice Thrown when trying to remove a reward token that doesn't exist */
    error RewardTokenDoesNotExist();

    /* @notice Thrown when trying to change the rewards duration of a reward token */
    error CannotChangeRewardsDuration();

    /* @notice Thrown when a reward token still has a balance */
    error RewardTokenStillHasBalance(uint256 balance);

    /* @notice Thrown when the index is out of bounds */
    error IndexOutOfBounds();

    /* @notice Thrown when the rewards duration is zero */
    error RewardsDurationCannotBeZero();

    /* @notice Thrown when attempting to unstake zero tokens */
    error CannotUnstakeZero();

    /* @notice Thrown when the rewards duration is too long */
    error RewardsDurationTooLong();

    /**
     * @notice Thrown when the receiver is the zero address
     */
    error CannotStakeToZeroAddress();
}
