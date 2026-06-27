// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@rari-capital/solmate/src/utils/SafeTransferLib.sol';
import '@rari-capital/solmate/src/tokens/ERC20.sol';
import '../interfaces/IBribe.sol';

interface IVoter {
    // lpToken => weight, equals to sum of votes for a LP token
    function weights(address _lpToken) external view returns (uint256);

    // user address => lpToken => votes
    function votes(address _user, address _lpToken) external view returns (uint256);
}

/**
 * Simple bribe per sec. Distribute bribe rewards to voters
 * fork from SimpleRewarder.
 * Bribe.onVote->updatePool() is a bit different from SimpleRewarder.
 * Here we reduce the original total amount of share
 */
contract Bribe is IBribe, Ownable, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    uint256 public immutable ACC_TOKEN_PRECISION;
    ERC20 public immutable override rewardToken;
    address public immutable lpToken;
    bool public immutable isNative;
    address public immutable voter;

    /// @notice Info of each voter user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of YOUR_TOKEN entitled to the user.
    struct UserInfo {
        uint128 amount; // 20.18 fixed point
        uint128 rewardDebt; // 26.12 fixed point
        uint256 unpaidRewards;
    }

    /// @notice Info of each voter poolInfo.
    /// `accTokenPerShare` Amount of YOUR_TOKEN each LP token is worth.
    /// `lastRewardTimestamp` The last timestamp YOUR_TOKEN was rewarded to the poolInfo.
    struct PoolInfo {
        uint128 accTokenPerShare; // 20.18 fixed point
        uint48 lastRewardTimestamp;
    }

    /// @notice address of the operator
    /// @dev operator is able to set emission rate
    address public operator;

    /// @notice Info of the poolInfo.
    PoolInfo public poolInfo;
    /// @notice Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    uint256 public tokenPerSec;

    event OnReward(address indexed user, uint256 amount);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    modifier onlyVoter() {
        require(msg.sender == address(voter), 'onlyVoter: only MasterPlatypus can call this function');
        _;
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == owner() || msg.sender == operator, 'onlyOperatorOrOwner');
        _;
    }

    constructor(
        address _voter,
        address _lpToken,
        ERC20 _rewardToken,
        uint256 _tokenPerSec,
        bool _isNative
    ) {
        require(Address.isContract(address(_rewardToken)), 'constructor: reward token must be a valid contract');
        require(Address.isContract(address(_lpToken)), 'constructor: LP token must be a valid contract');
        require(Address.isContract(address(_voter)), 'constructor: Voter must be a valid contract');
        require(_rewardToken.decimals() <= 30, 'constructor: too much decimal for _rewardToken');

        ACC_TOKEN_PRECISION = 1e30 / (10**_rewardToken.decimals());

        voter = _voter;
        lpToken = _lpToken;
        rewardToken = _rewardToken;
        tokenPerSec = _tokenPerSec;
        isNative = _isNative;
        poolInfo = PoolInfo({lastRewardTimestamp: uint48(block.timestamp), accTokenPerShare: 0});
    }

    /// @notice Set operator address
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    /// @notice Update reward variables of the given poolInfo.
    function updatePool() public {
        PoolInfo memory pool = poolInfo;

        if (block.timestamp > pool.lastRewardTimestamp) {
            uint256 totalShares = _getTotalShare();

            if (totalShares > 0) {
                uint256 timeElapsed = block.timestamp - pool.lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * tokenPerSec;
                pool.accTokenPerShare += toUint128((tokenReward * ACC_TOKEN_PRECISION) / totalShares);
            }

            pool.lastRewardTimestamp = uint48(block.timestamp);
            poolInfo = pool;
        }
    }

    /// @notice Sets the distribution reward rate. This will also update the poolInfo.
    /// @param _tokenPerSec The number of tokens to distribute per second
    function setRewardRate(uint256 _tokenPerSec) external onlyOperatorOrOwner {
        require(_tokenPerSec <= 10000e18, 'reward rate too high'); // in case of accTokenPerShare overflow
        updatePool();

        uint256 oldRate = tokenPerSec;
        tokenPerSec = _tokenPerSec;

        emit RewardRateUpdated(oldRate, _tokenPerSec);
    }

    /// @notice Function called by Voter whenever user update his vote of claim rewards
    /// @notice Allows users to receive bribes
    /// @dev assumes that _getTotalShare() returns the new amount of share
    /// @param _user Address of user
    /// @param _lpAmount Number of vote the user has
    function onVote(
        address _user,
        uint256 _lpAmount,
        uint256 originalTotalVotes
    ) external override onlyVoter nonReentrant returns (uint256) {
        PoolInfo storage pool = poolInfo;
        UserInfo storage user = userInfo[_user];

        // update pool using the original total votes
        if (block.timestamp > pool.lastRewardTimestamp) {
            if (originalTotalVotes > 0) {
                uint256 timeElapsed = block.timestamp - pool.lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * tokenPerSec;
                pool.accTokenPerShare += toUint128((tokenReward * ACC_TOKEN_PRECISION) / originalTotalVotes);
            }

            pool.lastRewardTimestamp = uint48(block.timestamp);
        }

        uint256 pending;
        uint256 totalSent;
        if (user.amount > 0) {
            pending =
                ((user.amount * uint256(pool.accTokenPerShare)) / ACC_TOKEN_PRECISION) -
                (user.rewardDebt) +
                (user.unpaidRewards);

            if (isNative) {
                uint256 tokenBalance = address(this).balance;
                if (pending > tokenBalance) {
                    (bool success, ) = _user.call{value: tokenBalance}('');
                    totalSent = tokenBalance;
                    require(success, 'Transfer failed');
                    user.unpaidRewards = pending - tokenBalance;
                } else {
                    (bool success, ) = _user.call{value: pending}('');
                    totalSent = pending;
                    require(success, 'Transfer failed');
                    user.unpaidRewards = 0;
                }
            } else {
                uint256 tokenBalance = rewardToken.balanceOf(address(this));
                if (pending > tokenBalance) {
                    rewardToken.safeTransfer(_user, tokenBalance);
                    totalSent = tokenBalance;
                    user.unpaidRewards = pending - tokenBalance;
                } else {
                    rewardToken.safeTransfer(_user, pending);
                    totalSent = pending;
                    user.unpaidRewards = 0;
                }
            }
        }

        user.amount = toUint128(_lpAmount);
        user.rewardDebt = toUint128((user.amount * uint256(pool.accTokenPerShare)) / ACC_TOKEN_PRECISION);
        emit OnReward(_user, totalSent);
        return totalSent;
    }

    /// @notice View function to see pending tokens
    /// @param _user Address of user.
    /// @return pending reward for a given user.
    function pendingTokens(address _user) external view override returns (uint256 pending) {
        PoolInfo memory pool = poolInfo;
        UserInfo storage user = userInfo[_user];

        uint256 accTokenPerShare = pool.accTokenPerShare;
        uint256 totalShares = _getTotalShare();

        if (block.timestamp > pool.lastRewardTimestamp && totalShares != 0) {
            uint256 timeElapsed = block.timestamp - (pool.lastRewardTimestamp);
            uint256 tokenReward = timeElapsed * (tokenPerSec);
            accTokenPerShare = accTokenPerShare + ((tokenReward * (ACC_TOKEN_PRECISION)) / totalShares);
        }

        pending =
            ((user.amount * uint256(accTokenPerShare)) / ACC_TOKEN_PRECISION) -
            (user.rewardDebt) +
            (user.unpaidRewards);
    }

    /// @notice In case rewarder is stopped before emissions finished, this function allows
    /// withdrawal of remaining tokens.
    function emergencyWithdraw() external onlyOwner {
        if (isNative) {
            (bool success, ) = msg.sender.call{value: address(this).balance}('');
            require(success, 'Transfer failed');
        } else {
            rewardToken.safeTransfer(address(msg.sender), rewardToken.balanceOf(address(this)));
        }
    }

    /// @notice avoids loosing funds in case there is any tokens sent to this contract
    function emergencyTokenWithdraw(address token) external onlyOwner {
        // send that balance back to owner
        ERC20(token).safeTransfer(msg.sender, ERC20(token).balanceOf(address(this)));
    }

    /// @notice View function to see balance of reward token.
    function balance() external view returns (uint256) {
        if (isNative) {
            return address(this).balance;
        } else {
            return rewardToken.balanceOf(address(this));
        }
    }

    function _getTotalShare() internal view returns (uint256) {
        return IVoter(voter).weights(lpToken);
    }

    function toUint128(uint256 val) internal pure returns (uint128) {
        if (val > type(uint128).max) revert('uint128 overflow');
        return uint128(val);
    }

    /// @notice payable function needed to receive AVAX
    receive() external payable {}
}
