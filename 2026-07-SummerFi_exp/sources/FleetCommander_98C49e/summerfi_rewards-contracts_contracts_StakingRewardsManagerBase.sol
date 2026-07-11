// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title StakingRewardsManager
 * @notice Contract for managing staking rewards with multiple reward tokens in the Summer protocol
 * @dev Implements IStakingRewards interface and inherits from ReentrancyGuardTransient and ProtocolAccessManaged
 * @dev Inspired by Synthetix's StakingRewards contract:
 * https://github.com/Synthetixio/synthetix/blob/v2.101.3/contracts/StakingRewards.sol
 */
import {IStakingRewardsManagerBase} from "../interfaces/IStakingRewardsManagerBase.sol";
import {ProtocolAccessManaged} from "@summerfi/access-contracts/contracts/ProtocolAccessManaged.sol";
import {ReentrancyGuardTransient} from "@summerfi/dependencies/openzeppelin-next/ReentrancyGuardTransient.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Constants} from "@summerfi/constants/Constants.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";

/**
 * @title StakingRewards
 * @notice Contract for managing staking rewards with multiple reward tokens in the Summer protocol
 * @dev Implements IStakingRewards interface and inherits from ReentrancyGuardTransient and ProtocolAccessManaged
 */
abstract contract StakingRewardsManagerBase is
    IStakingRewardsManagerBase,
    ReentrancyGuardTransient,
    ProtocolAccessManaged
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct RewardData {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 rewardsDuration;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /* @notice List of all reward tokens supported by this contract */
    EnumerableSet.AddressSet internal _rewardTokensList;
    /* @notice The token that users stake to earn rewards */
    address public immutable stakingToken;

    /* @notice Mapping of reward token to its reward distribution data */
    mapping(address rewardToken => RewardData data) public rewardData;
    /* @notice Tracks the last reward per token paid to each user for each reward token */
    mapping(address rewardToken => mapping(address account => uint256 rewardPerTokenPaid))
        public userRewardPerTokenPaid;
    /* @notice Tracks the unclaimed rewards for each user for each reward token */
    mapping(address rewardToken => mapping(address account => uint256 rewardAmount))
        public rewards;

    /* @notice Total amount of tokens staked in the contract */
    uint256 public totalSupply;
    mapping(address account => uint256 balance) internal _balances;

    uint256 private constant MAX_REWARD_DURATION = 360 days; // 1 year

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier updateReward(address account) virtual {
        _updateReward(account);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the StakingRewards contract
     * @param accessManager The address of the access manager
     */
    constructor(address accessManager) ProtocolAccessManaged(accessManager) {}

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingRewardsManagerBase
    function rewardTokens(
        uint256 index
    ) external view override returns (address) {
        if (index >= _rewardTokensList.length()) revert IndexOutOfBounds();
        address rewardTokenAddress = _rewardTokensList.at(index);
        return rewardTokenAddress;
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function rewardTokensLength() external view returns (uint256) {
        return _rewardTokensList.length();
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function lastTimeRewardApplicable(
        address rewardToken
    ) public view returns (uint256) {
        return
            block.timestamp < rewardData[rewardToken].periodFinish
                ? block.timestamp
                : rewardData[rewardToken].periodFinish;
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function rewardPerToken(address rewardToken) public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardData[rewardToken].rewardPerTokenStored;
        }
        return
            rewardData[rewardToken].rewardPerTokenStored +
            ((lastTimeRewardApplicable(rewardToken) -
                rewardData[rewardToken].lastUpdateTime) *
                rewardData[rewardToken].rewardRate) /
            totalSupply;
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function earned(
        address account,
        address rewardToken
    ) public view virtual returns (uint256) {
        return _earned(account, rewardToken);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function getRewardForDuration(
        address rewardToken
    ) external view returns (uint256) {
        RewardData storage data = rewardData[rewardToken];
        if (block.timestamp >= data.periodFinish) {
            return (data.rewardRate * data.rewardsDuration) / Constants.WAD;
        }
        // For active periods, calculate remaining rewards plus any new rewards
        uint256 remaining = data.periodFinish - block.timestamp;
        return (data.rewardRate * remaining) / Constants.WAD;
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function isRewardToken(address rewardToken) external view returns (bool) {
        return _isRewardToken(rewardToken);
    }

    /*//////////////////////////////////////////////////////////////
                            MUTATIVE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingRewardsManagerBase
    function stake(uint256 amount) external virtual updateReward(_msgSender()) {
        _stake(_msgSender(), _msgSender(), amount);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function unstake(
        uint256 amount
    ) external virtual updateReward(_msgSender()) {
        _unstake(_msgSender(), _msgSender(), amount);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function getReward() public virtual nonReentrant {
        uint256 rewardTokenCount = _rewardTokensList.length();
        for (uint256 i = 0; i < rewardTokenCount; i++) {
            address rewardTokenAddress = _rewardTokensList.at(i);
            _getReward(_msgSender(), rewardTokenAddress);
        }
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function getReward(address rewardToken) public virtual nonReentrant {
        if (!_isRewardToken(rewardToken)) revert RewardTokenDoesNotExist();
        _getReward(_msgSender(), rewardToken);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function exit() external virtual {
        getReward();
        _unstake(_msgSender(), _msgSender(), _balances[_msgSender()]);
    }

    /// @notice Claims rewards for a specific account
    /// @param account The address to claim rewards for
    function getRewardFor(address account) public virtual nonReentrant {
        uint256 rewardTokenCount = _rewardTokensList.length();
        for (uint256 i = 0; i < rewardTokenCount; i++) {
            address rewardTokenAddress = _rewardTokensList.at(i);
            _getReward(account, rewardTokenAddress);
        }
    }

    /// @notice Claims rewards for a specific account and specific reward token
    /// @param account The address to claim rewards for
    /// @param rewardToken The address of the reward token to claim
    function getRewardFor(
        address account,
        address rewardToken
    ) public virtual nonReentrant {
        if (!_isRewardToken(rewardToken)) revert RewardTokenDoesNotExist();
        _getReward(account, rewardToken);
    }

    /*//////////////////////////////////////////////////////////////
                            RESTRICTED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IStakingRewardsManagerBase
    function notifyRewardAmount(
        address rewardToken,
        uint256 reward,
        uint256 newRewardsDuration
    ) external virtual onlyGovernor updateReward(address(0)) {
        _notifyRewardAmount(rewardToken, reward, newRewardsDuration);
    }

    /// @inheritdoc IStakingRewardsManagerBase
    function setRewardsDuration(
        address rewardToken,
        uint256 _rewardsDuration
    ) external onlyGovernor {
        if (!_isRewardToken(rewardToken)) {
            revert RewardTokenDoesNotExist();
        }
        if (_rewardsDuration == 0) {
            revert RewardsDurationCannotBeZero();
        }
        if (_rewardsDuration > MAX_REWARD_DURATION) {
            revert RewardsDurationTooLong();
        }

        RewardData storage data = rewardData[rewardToken];
        if (block.timestamp <= data.periodFinish) {
            revert RewardPeriodNotComplete();
        }
        data.rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(address(rewardToken), _rewardsDuration);
    }

    /// @notice Removes a reward token from the list of reward tokens
    /// @param rewardToken The address of the reward token to remove
    function removeRewardToken(address rewardToken) external onlyGovernor {
        if (!_isRewardToken(rewardToken)) {
            revert RewardTokenDoesNotExist();
        }

        if (block.timestamp <= rewardData[rewardToken].periodFinish) {
            revert RewardPeriodNotComplete();
        }

        // Check if all tokens have been claimed, allowing a small dust balance
        uint256 remainingBalance = IERC20(rewardToken).balanceOf(address(this));
        uint256 dustThreshold;

        try IERC20Metadata(address(rewardToken)).decimals() returns (
            uint8 decimals
        ) {
            // For tokens with 4 or fewer decimals, use a minimum threshold of 1
            // For tokens with more decimals, use 0.01% of 1 token
            if (decimals <= 4) {
                dustThreshold = 1;
            } else {
                dustThreshold = 10 ** (decimals - 4); // 0.01% of 1 token
            }
        } catch {
            dustThreshold = 1e14; // Default threshold for tokens without decimals
        }

        if (remainingBalance > dustThreshold) {
            revert RewardTokenStillHasBalance(remainingBalance);
        }

        // Remove the token from the rewardTokens map
        bool success = _rewardTokensList.remove(address(rewardToken));
        if (!success) revert RewardTokenDoesNotExist();

        emit RewardTokenRemoved(address(rewardToken));
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _isRewardToken(address rewardToken) internal view returns (bool) {
        return _rewardTokensList.contains(rewardToken);
    }

    function _stake(
        address staker,
        address receiver,
        uint256 amount
    ) internal virtual {
        if (receiver == address(0)) revert CannotStakeToZeroAddress();
        if (amount == 0) revert CannotStakeZero();
        if (address(stakingToken) == address(0)) {
            revert StakingTokenNotInitialized();
        }
        totalSupply += amount;
        _balances[receiver] += amount;
        IERC20(stakingToken).safeTransferFrom(staker, address(this), amount);
        emit Staked(staker, receiver, amount);
    }

    function _unstake(
        address staker,
        address receiver,
        uint256 amount
    ) internal virtual {
        if (amount == 0) revert CannotUnstakeZero();
        totalSupply -= amount;
        _balances[staker] -= amount;
        IERC20(stakingToken).safeTransfer(receiver, amount);
        emit Unstaked(staker, receiver, amount);
    }

    /*
     * @notice Internal function to calculate earned rewards for an account
     * @param account The address to calculate earnings for
     * @param rewardToken The reward token to calculate earnings for
     * @return The amount of reward tokens earned
     */
    function _earned(
        address account,
        address rewardToken
    ) internal view returns (uint256) {
        return
            (_balances[account] *
                (rewardPerToken(rewardToken) -
                    userRewardPerTokenPaid[rewardToken][account])) /
            Constants.WAD +
            rewards[rewardToken][account];
    }

    function _updateReward(address account) internal {
        uint256 rewardTokenCount = _rewardTokensList.length();
        for (uint256 i = 0; i < rewardTokenCount; i++) {
            address rewardTokenAddress = _rewardTokensList.at(i);
            RewardData storage rewardTokenData = rewardData[rewardTokenAddress];
            rewardTokenData.rewardPerTokenStored = rewardPerToken(
                rewardTokenAddress
            );
            rewardTokenData.lastUpdateTime = lastTimeRewardApplicable(
                rewardTokenAddress
            );
            if (account != address(0)) {
                rewards[rewardTokenAddress][account] = earned(
                    account,
                    rewardTokenAddress
                );
                userRewardPerTokenPaid[rewardTokenAddress][
                    account
                ] = rewardTokenData.rewardPerTokenStored;
            }
        }
    }

    /**
     * @notice Internal function to claim rewards for an account for a specific token
     * @param account The address to claim rewards for
     * @param rewardTokenAddress The address of the reward token to claim
     * @dev rewards go straight to the user's wallet
     */
    function _getReward(
        address account,
        address rewardTokenAddress
    ) internal virtual updateReward(account) {
        uint256 reward = rewards[rewardTokenAddress][account];
        if (reward > 0) {
            rewards[rewardTokenAddress][account] = 0;
            IERC20(rewardTokenAddress).safeTransfer(account, reward);
            emit RewardPaid(account, rewardTokenAddress, reward);
        }
    }

    /**
     * @dev Internal implementation of notifyRewardAmount
     * @param rewardToken The token to distribute as rewards
     * @param reward The amount of reward tokens to distribute
     * @param newRewardsDuration The duration for new reward tokens (only used for first time)
     */
    function _notifyRewardAmount(
        address rewardToken,
        uint256 reward,
        uint256 newRewardsDuration
    ) internal {
        RewardData storage rewardTokenData = rewardData[rewardToken];
        if (newRewardsDuration == 0) {
            revert RewardsDurationCannotBeZero();
        }

        if (newRewardsDuration > MAX_REWARD_DURATION) {
            revert RewardsDurationTooLong();
        }

        // For existing reward tokens, check if current period is complete
        if (_isRewardToken(rewardToken)) {
            if (newRewardsDuration != rewardTokenData.rewardsDuration) {
                revert CannotChangeRewardsDuration();
            }
        } else {
            // First time setup for new reward token
            bool success = _rewardTokensList.add(rewardToken);
            if (!success) revert RewardTokenAlreadyExists();

            rewardTokenData.rewardsDuration = newRewardsDuration;
            emit RewardTokenAdded(rewardToken, rewardTokenData.rewardsDuration);
        }

        // Transfer exact amount needed for new rewards
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), reward);

        // Calculate new reward rate
        rewardTokenData.rewardRate =
            (reward * Constants.WAD) /
            rewardTokenData.rewardsDuration;
        rewardTokenData.lastUpdateTime = block.timestamp;
        rewardTokenData.periodFinish =
            block.timestamp +
            rewardTokenData.rewardsDuration;

        emit RewardAdded(address(rewardToken), reward);
    }
}
