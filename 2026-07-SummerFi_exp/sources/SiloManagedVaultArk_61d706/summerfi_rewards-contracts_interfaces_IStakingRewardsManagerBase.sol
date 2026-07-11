// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStakingRewardsManagerBaseErrors} from "./IStakingRewardsManagerBaseErrors.sol";

/* @title IStakingRewardsManagerBase
 * @notice Interface for the Staking Rewards Manager contract
 * @dev Manages staking and distribution of multiple reward tokens
 */
interface IStakingRewardsManagerBase is IStakingRewardsManagerBaseErrors {
    // Views

    /* @notice Get the total amount of staked tokens
     * @return The total supply of staked tokens
     */
    function totalSupply() external view returns (uint256);

    /* @notice Get the staked balance of a specific account
     * @param account The address of the account to check
     * @return The staked balance of the account
     */
    function balanceOf(address account) external view returns (uint256);

    /* @notice Get the last time the reward was applicable for a specific reward token
     * @param rewardToken The address of the reward token
     * @return The timestamp of the last applicable reward time
     */
    function lastTimeRewardApplicable(
        address rewardToken
    ) external view returns (uint256);

    /* @notice Get the reward per token for a specific reward token
     * @param rewardToken The address of the reward token
     * @return The reward amount per staked token (WAD-scaled)
     * @dev Returns a WAD-scaled value (1e18) to maintain precision in calculations
     * @dev This value represents: (rewardRate * timeElapsed * WAD) / totalSupply
     */
    function rewardPerToken(
        address rewardToken
    ) external view returns (uint256);

    /* @notice Calculate the earned reward for an account and a specific reward token
     * @param account The address of the account
     * @param rewardToken The address of the reward token
     * @return The amount of reward tokens earned (not WAD-scaled)
     * @dev Calculated as: (balance * (rewardPerToken - userRewardPerTokenPaid)) / WAD + rewards
     */
    function earned(
        address account,
        address rewardToken
    ) external view returns (uint256);

    /* @notice Get the reward for the entire duration for a specific reward token
     * @param rewardToken The address of the reward token
     * @return The total reward amount for the duration (not WAD-scaled)
     * @dev Calculated as: (rewardRate * rewardsDuration) / WAD
     */
    function getRewardForDuration(
        address rewardToken
    ) external view returns (uint256);

    /* @notice Get the address of the staking token
     * @return The address of the staking token
     */
    function stakingToken() external view returns (address);

    /* @notice Get the reward token at a specific index
     * @param index The index of the reward token
     * @return The address of the reward token
     * @dev Reverts with IndexOutOfBounds if index >= rewardTokensLength()
     */
    function rewardTokens(uint256 index) external view returns (address);

    /* @notice Get the total number of reward tokens
     * @return The length of the reward tokens list
     */
    function rewardTokensLength() external view returns (uint256);

    /* @notice Check if a token is in the list of reward tokens
     * @param rewardToken The address to check
     * @return bool True if the token is a reward token, false otherwise
     */
    function isRewardToken(address rewardToken) external view returns (bool);

    // Mutative functions

    /* @notice Stake tokens for an account
     * @param amount The amount of tokens to stake
     */
    function stake(uint256 amount) external;

    /* @notice Stake tokens for an account on behalf of another account
     * @param receiver The address of the account to stake for
     * @param amount The amount of tokens to stake
     */
    function stakeOnBehalfOf(address receiver, uint256 amount) external;

    /* @notice Unstake staked tokens on behalf of another account
     * @param owner The address of the account to unstake from
     * @param amount The amount of tokens to unstake
     * @param claimRewards Whether to claim rewards before unstaking
     */
    function unstakeAndWithdrawOnBehalfOf(
        address owner,
        uint256 amount,
        bool claimRewards
    ) external;

    /* @notice Unstake staked tokens
     * @param amount The amount of tokens to unstake
     */
    function unstake(uint256 amount) external;

    /* @notice Claim accumulated rewards for all reward tokens */
    function getReward() external;

    /* @notice Claim accumulated rewards for a specific reward token
     * @param rewardToken The address of the reward token to claim
     */
    function getReward(address rewardToken) external;

    /* @notice Withdraw all staked tokens and claim rewards */
    function exit() external;

    // Admin functions

    /* @notice Notify the contract about new reward amount
     * @param rewardToken The address of the reward token
     * @param reward The amount of new reward (not WAD-scaled)
     * @param newRewardsDuration The duration for rewards distribution (only used when adding a new reward token)
     * @dev Internally sets rewardRate as (reward * WAD) / duration to maintain precision
     */
    function notifyRewardAmount(
        address rewardToken,
        uint256 reward,
        uint256 newRewardsDuration
    ) external;

    /* @notice Set the duration for rewards distribution
     * @param rewardToken The address of the reward token
     * @param _rewardsDuration The new duration for rewards
     */
    function setRewardsDuration(
        address rewardToken,
        uint256 _rewardsDuration
    ) external;

    /* @notice Removes a reward token from the list of reward tokens
     * @dev Can only be called by governor
     * @dev Can only be called after reward period is complete
     * @dev Can only be called if remaining balance is below dust threshold
     * @param rewardToken The address of the reward token to remove
     */
    function removeRewardToken(address rewardToken) external;

    // Events

    /* @notice Emitted when a new reward is added
     * @param rewardToken The address of the reward token
     * @param reward The amount of reward added
     */
    event RewardAdded(address indexed rewardToken, uint256 reward);

    /* @notice Emitted when tokens are staked
     * @param staker The address that provided the tokens for staking
     * @param receiver The address whose staking balance was updated
     * @param amount The amount of tokens added to the staking position
     */
    event Staked(
        address indexed staker,
        address indexed receiver,
        uint256 amount
    );

    /* @notice Emitted when tokens are unstaked
     * @param staker The address whose tokens were unstaked
     * @param receiver The address receiving the unstaked tokens
     * @param amount The amount of tokens unstaked
     */
    event Unstaked(
        address indexed staker,
        address indexed receiver,
        uint256 amount
    );

    /* @notice Emitted when tokens are withdrawn
     * @param user The address of the user that withdrew
     * @param amount The amount of tokens withdrawn
     */
    event Withdrawn(address indexed user, uint256 amount);

    /* @notice Emitted when rewards are paid out
     * @param user The address of the user receiving the reward
     * @param rewardToken The address of the reward token
     * @param reward The amount of reward paid
     */
    event RewardPaid(
        address indexed user,
        address indexed rewardToken,
        uint256 reward
    );

    /* @notice Emitted when the rewards duration is updated
     * @param rewardToken The address of the reward token
     * @param newDuration The new duration for rewards
     */
    event RewardsDurationUpdated(
        address indexed rewardToken,
        uint256 newDuration
    );

    /* @notice Emitted when a new reward token is added
     * @param rewardToken The address of the new reward token
     * @param rewardsDuration The duration for the new reward token
     */
    event RewardTokenAdded(address rewardToken, uint256 rewardsDuration);

    /* @notice Emitted when a reward token is removed
     * @param rewardToken The address of the reward token
     */
    event RewardTokenRemoved(address rewardToken);

    /* @notice Claims rewards for a specific account
     * @param account The address to claim rewards for
     */
    function getRewardFor(address account) external;

    /* @notice Claims rewards for a specific account and specific reward token
     * @param account The address to claim rewards for
     * @param rewardToken The address of the reward token to claim
     */
    function getRewardFor(address account, address rewardToken) external;
}
