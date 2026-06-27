// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IPRXVTStaking
 * @notice Interface for the PRXVT Staking contract
 * @dev Combines staking functionality with embedded stPRXVT ERC20 receipt token
 */
interface IPRXVTStaking is IERC20 {
    // ============ Structs ============

    struct BoostInfo {
        uint256 multiplier; // 1e18 to 2e18 (1x to 2x)
        uint256 expiresAt; // Timestamp when boost expires
        string reason; // Reason for boost assignment
    }

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardBurned(address indexed user, uint256 amount);
    event RewardAdded(uint256 reward);
    event BurnFeeUpdated(uint256 oldFee, uint256 newFee);
    event BoostApplied(address indexed user, uint256 multiplier, uint256 expiresAt, string reason);
    event MinimumStakeUpdated(uint256 oldMinimum, uint256 newMinimum);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);

    // ============ User Functions ============

    /**
     * @notice Stake PRXVT tokens to earn rewards
     * @param amount Amount of PRXVT to stake
     */
    function stake(uint256 amount) external;

    /**
     * @notice Withdraw staked PRXVT tokens (instant, no penalties)
     * @param amount Amount of stPRXVT to burn and PRXVT to withdraw
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Claim earned rewards (burn fee applied)
     */
    function claimReward() external;

    /**
     * @notice Withdraw all staked tokens and claim rewards in one transaction
     */
    function exit() external;

    // ============ View Functions ============

    /**
     * @notice Calculate earned rewards for an account (including boost)
     * @param account Address to check
     * @return Total earned rewards
     */
    function earned(address account) external view returns (uint256);

    /**
     * @notice Get comprehensive user information
     * @param user Address to check
     * @return balance User's staked balance (stPRXVT)
     * @return earnedAmount Total earned rewards
     * @return claimableAmount Amount user will receive after burn fee
     * @return burnAmount Amount that will be burned on claim
     * @return multiplier Current boost multiplier (1e18 if no boost)
     * @return boostReason Reason for boost
     * @return boostExpiresIn Seconds until boost expires (0 if expired/no boost)
     */
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 balance,
            uint256 earnedAmount,
            uint256 claimableAmount,
            uint256 burnAmount,
            uint256 multiplier,
            string memory boostReason,
            uint256 boostExpiresIn
        );

    /**
     * @notice Get pool information
     * @return totalStaked Total amount of PRXVT staked
     * @return apy Approximate APY in basis points (e.g., 5000 = 50%)
     * @return currentRewardRate Current reward rate per second
     * @return periodEndsIn Seconds until current reward period ends
     * @return totalBurnedAmount Lifetime total burned amount
     * @return isPausedStatus Whether contract is paused
     */
    function getPoolInfo()
        external
        view
        returns (
            uint256 totalStaked,
            uint256 apy,
            uint256 currentRewardRate,
            uint256 periodEndsIn,
            uint256 totalBurnedAmount,
            bool isPausedStatus
        );

    /**
     * @notice Preview claim results without executing
     * @param user Address to preview
     * @return earnedAmount Total earned
     * @return burnAmount Amount that will be burned
     * @return userReceives Amount user will receive
     */
    function previewClaim(address user)
        external
        view
        returns (uint256 earnedAmount, uint256 burnAmount, uint256 userReceives);

    /**
     * @notice Get reward per token stored
     */
    function rewardPerToken() external view returns (uint256);

    /**
     * @notice Get last time reward applicable
     */
    function lastTimeRewardApplicable() external view returns (uint256);

    /**
     * @notice Get total staked amount
     */
    function totalStaked() external view returns (uint256);

    // ============ Admin Functions ============

    /**
     * @notice Fund the reward pool for the next period
     * @param reward Amount of PRXVT to distribute as rewards
     */
    function notifyRewardAmount(uint256 reward) external;

    /**
     * @notice Update burn fee percentage
     * @param _burnFeePercent New burn fee in basis points (0-5000)
     */
    function setBurnFee(uint256 _burnFeePercent) external;

    /**
     * @notice Apply boost multiplier to a user
     * @param user Address to boost
     * @param multiplier Boost multiplier (1e18 to 2e18)
     * @param reason Reason for boost
     */
    function applyBoost(address user, uint256 multiplier, string calldata reason) external;

    /**
     * @notice Apply boosts to multiple users
     * @param users Array of addresses to boost
     * @param multipliers Array of multipliers
     * @param reasons Array of reasons
     */
    function applyBoostBatch(
        address[] calldata users,
        uint256[] calldata multipliers,
        string[] calldata reasons
    ) external;

    /**
     * @notice Update minimum stake amount
     * @param _minimumStake New minimum stake amount
     */
    function setMinimumStake(uint256 _minimumStake) external;

    /**
     * @notice Update rewards duration (only when period ended)
     * @param _rewardsDuration New duration in seconds
     */
    function setRewardsDuration(uint256 _rewardsDuration) external;

    /**
     * @notice Pause contract (blocks stake/claim, allows withdraw)
     */
    function pause() external;

    /**
     * @notice Unpause contract
     */
    function unpause() external;

    // ============ State Variables (Getters) ============

    function prxvtToken() external view returns (IERC20);

    function rewardRate() external view returns (uint256);

    function rewardsDuration() external view returns (uint256);

    function periodFinish() external view returns (uint256);

    function lastUpdateTime() external view returns (uint256);

    function rewardPerTokenStored() external view returns (uint256);

    function burnFeePercent() external view returns (uint256);

    function totalBurned() external view returns (uint256);

    function minimumStake() external view returns (uint256);

    function boosts(address user) external view returns (uint256 multiplier, uint256 expiresAt, string memory reason);

    function rewards(address user) external view returns (uint256);

    function userRewardPerTokenPaid(address user) external view returns (uint256);
}
