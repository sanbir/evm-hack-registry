// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IPRXVTStaking} from "./interfaces/IPRXVTStaking.sol";

/**
 * @title PRXVTStaking
 * @notice Staking contract for PRXVT token with embedded stPRXVT receipt token
 * @dev Implements Synthetix StakingRewards pattern with burn fees and boost multipliers
 *
 * Features:
 * - Stake PRXVT, receive stPRXVT (1:1)
 * - Earn rewards linearly distributed over time
 * - Configurable burn fee on reward claims (0-50%)
 * - Boost multipliers (1x-2x) for specific users
 * - Pausable with withdrawal escape hatch
 * - Instant withdrawals, no penalties
 */
contract PRXVTStaking is ERC20, Ownable2Step, ReentrancyGuard, Pausable, IPRXVTStaking {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Address where burned tokens are sent
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum burn fee (50% in basis points)
    uint256 public constant MAX_BURN_FEE = 5000;

    /// @notice Duration of boost multipliers
    uint256 public constant BOOST_DURATION = 7 days;

    /// @notice Precision multiplier for reward calculations
    uint256 public constant PRECISION = 1e18;

    // ============ Immutable State ============

    /// @notice PRXVT token address
    IERC20 public immutable prxvtToken;

    // ============ Reward Distribution (Synthetix Pattern) ============

    /// @notice Rewards distributed per second
    uint256 public rewardRate;

    /// @notice Duration of reward period (default 30 days)
    uint256 public rewardsDuration = 30 days;

    /// @notice Timestamp when current reward period ends
    uint256 public periodFinish;

    /// @notice Last time rewards were updated
    uint256 public lastUpdateTime;

    /// @notice Accumulated reward per token
    uint256 public rewardPerTokenStored;

    // ============ User Accounting ============

    /// @notice Reward per token already accounted for per user
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Pending rewards per user
    mapping(address => uint256) public rewards;

    // ============ Burn Fee System ============

    /// @notice Burn fee percentage in basis points (0-5000)
    uint256 public burnFeePercent = 1000; // Default 10%

    /// @notice Total amount burned over contract lifetime
    uint256 public totalBurned;

    // ============ Boost System ============

    /// @notice Boost information per user
    mapping(address => BoostInfo) private _boosts;

    // ============ Staking Configuration ============

    /// @notice Minimum stake amount for first-time stakers
    uint256 public minimumStake = 10_000e18; // 10,000 PRXVT

    /// @notice Total amount of PRXVT staked
    uint256 private _totalStaked;

    // ============ Constructor ============

    /**
     * @notice Initialize the staking contract
     * @param _prxvtToken Address of the PRXVT token
     */
    constructor(address _prxvtToken) ERC20("Staked PRXVT", "stPRXVT") Ownable(msg.sender) {
        require(_prxvtToken != address(0), "Invalid token address");
        prxvtToken = IERC20(_prxvtToken);
    }

    // ============ Modifiers ============

    /**
     * @notice Update rewards for an account before state changes
     * @param account Address to update rewards for (address(0) to update global state only)
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }

        _;
    }

    // ============ Synthetix Reward Pattern Functions ============

    /**
     * @notice Get the last time rewards are applicable
     * @return Timestamp of last applicable reward time
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Calculate accumulated reward per token
     * @return Reward per token value
     */
    function rewardPerToken() public view returns (uint256) {
        if (_totalStaked == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / _totalStaked;
    }

    /**
     * @notice Calculate earned rewards for an account (includes boost)
     * @param account Address to check
     * @return Total earned rewards including boost multiplier
     */
    function earned(address account) public view returns (uint256) {
        // Calculate base reward
        uint256 baseReward = (balanceOf(account) * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];

        // Apply boost if active
        BoostInfo storage boost = _boosts[account];
        if (boost.expiresAt > block.timestamp && boost.multiplier > PRECISION) {
            return (baseReward * boost.multiplier) / PRECISION;
        }

        return baseReward;
    }

    // ============ Core User Functions ============

    /**
     * @notice Stake PRXVT tokens to earn rewards
     * @param amount Amount of PRXVT to stake
     */
    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");

        // First-time stakers must meet minimum
        if (balanceOf(msg.sender) == 0) {
            require(amount >= minimumStake, "Below minimum stake");
        }

        // Update total staked
        _totalStaked += amount;

        // Mint stPRXVT 1:1
        _mint(msg.sender, amount);

        // Transfer PRXVT from user
        prxvtToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraw staked PRXVT tokens (instant, no penalties)
     * @param amount Amount of stPRXVT to burn and PRXVT to withdraw
     * @dev CRITICAL: No whenNotPaused modifier - this is the escape hatch
     */
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Update total staked
        _totalStaked -= amount;

        // Burn stPRXVT
        _burn(msg.sender, amount);

        // Return PRXVT to user
        prxvtToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim earned rewards (burn fee applied)
     */
    function claimReward() public nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to claim");

        // Reset user rewards
        rewards[msg.sender] = 0;

        // Calculate burn fee
        uint256 burnAmount = (reward * burnFeePercent) / 10_000;
        uint256 userAmount = reward - burnAmount;

        // Update total burned
        totalBurned += burnAmount;

        // Transfer to burn address if fee > 0
        if (burnAmount > 0) {
            prxvtToken.safeTransfer(BURN_ADDRESS, burnAmount);
            emit RewardBurned(msg.sender, burnAmount);
        }

        // Transfer remainder to user
        if (userAmount > 0) {
            prxvtToken.safeTransfer(msg.sender, userAmount);
        }

        emit RewardPaid(msg.sender, userAmount);
    }

    /**
     * @notice Withdraw all staked tokens and claim rewards in one transaction
     */
    function exit() external {
        uint256 balance = balanceOf(msg.sender);
        if (balance > 0) {
            withdraw(balance);
        }
        claimReward(); // Will revert if paused
    }

    // ============ Admin Functions ============

    /**
     * @notice Fund the reward pool for the next period
     * @param reward Amount of PRXVT to distribute as rewards
     * @dev Handles both new periods and topping up existing periods
     */
    function notifyRewardAmount(uint256 reward) external onlyOwner updateReward(address(0)) {
        require(reward > 0, "Reward must be positive");

        if (block.timestamp >= periodFinish) {
            // New period
            rewardRate = reward / rewardsDuration;
        } else {
            // Ongoing period - roll over remaining rewards
            uint256 remaining = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (reward + remaining) / rewardsDuration;
        }

        // Ensure contract has sufficient balance
        // Subtract staked amount to ensure rewards don't dip into principal
        uint256 balance = prxvtToken.balanceOf(address(this));
        require(rewardRate <= (balance - _totalStaked) / rewardsDuration, "Provided reward too high");

        // Update period finish
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward);
    }

    /**
     * @notice Update burn fee percentage
     * @param _burnFeePercent New burn fee in basis points (0-5000)
     */
    function setBurnFee(uint256 _burnFeePercent) external onlyOwner {
        require(_burnFeePercent <= MAX_BURN_FEE, "Exceeds max burn fee");

        uint256 oldFee = burnFeePercent;
        burnFeePercent = _burnFeePercent;

        emit BurnFeeUpdated(oldFee, _burnFeePercent);
    }

    /**
     * @notice Apply boost multiplier to a user
     * @param user Address to boost
     * @param multiplier Boost multiplier (1e18 to 2e18, i.e., 1x to 2x)
     * @param reason Reason for boost assignment
     */
    function applyBoost(address user, uint256 multiplier, string calldata reason)
        public
        onlyOwner
        updateReward(user)
    {
        require(multiplier >= PRECISION && multiplier <= PRECISION * 2, "Invalid multiplier");
        require(balanceOf(user) > 0, "User has no stake");

        _boosts[user] = BoostInfo({multiplier: multiplier, expiresAt: block.timestamp + BOOST_DURATION, reason: reason});

        emit BoostApplied(user, multiplier, block.timestamp + BOOST_DURATION, reason);
    }

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
    ) external onlyOwner {
        require(users.length == multipliers.length && users.length == reasons.length, "Array length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            applyBoost(users[i], multipliers[i], reasons[i]);
        }
    }

    /**
     * @notice Update minimum stake amount
     * @param _minimumStake New minimum stake amount
     */
    function setMinimumStake(uint256 _minimumStake) external onlyOwner {
        uint256 oldMinimum = minimumStake;
        minimumStake = _minimumStake;

        emit MinimumStakeUpdated(oldMinimum, _minimumStake);
    }

    /**
     * @notice Update rewards duration (only when period ended)
     * @param _rewardsDuration New duration in seconds
     */
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(block.timestamp >= periodFinish, "Previous period must be complete");

        uint256 oldDuration = rewardsDuration;
        rewardsDuration = _rewardsDuration;

        emit RewardsDurationUpdated(oldDuration, _rewardsDuration);
    }

    /**
     * @notice Pause contract (blocks stake/claim, allows withdraw)
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ View Functions ============

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
        )
    {
        balance = balanceOf(user);
        earnedAmount = earned(user);

        // Calculate claimable after burn fee
        burnAmount = (earnedAmount * burnFeePercent) / 10_000;
        claimableAmount = earnedAmount - burnAmount;

        // Boost info
        BoostInfo storage boost = _boosts[user];
        multiplier = boost.expiresAt > block.timestamp ? boost.multiplier : PRECISION;
        boostReason = boost.reason;
        boostExpiresIn = boost.expiresAt > block.timestamp ? boost.expiresAt - block.timestamp : 0;

        return (balance, earnedAmount, claimableAmount, burnAmount, multiplier, boostReason, boostExpiresIn);
    }

    /**
     * @notice Get pool information
     * @return totalStaked_ Total amount of PRXVT staked
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
            uint256 totalStaked_,
            uint256 apy,
            uint256 currentRewardRate,
            uint256 periodEndsIn,
            uint256 totalBurnedAmount,
            bool isPausedStatus
        )
    {
        totalStaked_ = _totalStaked;
        currentRewardRate = rewardRate;
        periodEndsIn = periodFinish > block.timestamp ? periodFinish - block.timestamp : 0;
        totalBurnedAmount = totalBurned;
        isPausedStatus = paused();

        // Calculate APY (approximate, without compounding)
        if (_totalStaked > 0 && rewardRate > 0) {
            // APY = (rewardRate * 365 days * 100) / totalStaked
            apy = (rewardRate * 365 days * 100) / _totalStaked;
        } else {
            apy = 0;
        }

        return (totalStaked_, apy, currentRewardRate, periodEndsIn, totalBurnedAmount, isPausedStatus);
    }

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
        returns (uint256 earnedAmount, uint256 burnAmount, uint256 userReceives)
    {
        earnedAmount = earned(user);
        burnAmount = (earnedAmount * burnFeePercent) / 10_000;
        userReceives = earnedAmount - burnAmount;

        return (earnedAmount, burnAmount, userReceives);
    }

    /**
     * @notice Get total staked amount
     * @return Total PRXVT staked
     */
    function totalStaked() external view returns (uint256) {
        return _totalStaked;
    }

    /**
     * @notice Get boost information for a user
     * @param user Address to check
     * @return multiplier Boost multiplier
     * @return expiresAt Expiration timestamp
     * @return reason Boost reason
     */
    function boosts(address user) external view returns (uint256 multiplier, uint256 expiresAt, string memory reason) {
        BoostInfo storage boost = _boosts[user];
        return (boost.multiplier, boost.expiresAt, boost.reason);
    }

    // ============ ERC20 Overrides ============

    /**
     * @notice Override totalSupply to return total staked amount
     * @return Total supply of stPRXVT (equals total staked PRXVT)
     */
    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return _totalStaked;
    }
}
