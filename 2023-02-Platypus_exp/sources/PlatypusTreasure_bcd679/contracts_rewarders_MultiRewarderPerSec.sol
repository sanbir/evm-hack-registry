// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import '../interfaces/IMasterPlatypusV4.sol';
import '../interfaces/IMultiRewarder.sol';

/**
 * This is a sample contract to be used in the MasterPlatypus contract for partners to reward
 * stakers with their native token alongside PTP.
 *
 * It assumes no minting rights, so requires a set amount of reward tokens to be transferred to this contract prior.
 * E.g. say you've allocated 100,000 XYZ to the PTP-XYZ farm over 30 days. Then you would need to transfer
 * 100,000 XYZ and set the block reward accordingly so it's fully distributed after 30 days.
 *
 * - This contract has no knowledge on the LP amount and MasterPlatypus is
 *   responsible to pass the amount into this contract
 * - Supports multiple reward tokens
 */
contract MultiRewarderPerSec is IMultiRewarder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC_TOKEN_PRECISION = 1e12;
    IERC20 public immutable lpToken;
    IMasterPlatypusV4 public immutable MP;

    struct UserInfo {
        // if the pool is activated, rewardDebt should be > 0
        uint128 rewardDebt; // 20.18 fixed point. distributed reward per weight
        uint128 claimable; // 20.18 fixed point. claimable REWARD
    }

    /// @notice Info of each MP poolInfo.
    struct PoolInfo {
        IERC20 rewardToken; // if rewardToken is 0, native token is used as reward token
        uint96 tokenPerSec; // 10.18 fixed point
        uint128 accTokenPerShare; // 26.12 fixed point. Amount of reward token each LP token is worth.
    }

    /// @notice address of the operator
    /// @dev operator is able to set emission rate
    address public operator;

    uint256 public lastRewardTimestamp;

    /// @notice Info of the poolInfo.
    PoolInfo[] public poolInfo;
    /// @notice tokenId => userId => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event OnReward(address indexed rewardToken, address indexed user, uint256 amount);
    event RewardRateUpdated(address indexed rewardToken, uint256 oldRate, uint256 newRate);

    modifier onlyMP() {
        require(msg.sender == address(MP), 'onlyMP: only MasterPlatypus can call this function');
        _;
    }

    modifier onlyOperatorOrOwner() {
        require(msg.sender == owner() || msg.sender == operator, 'onlyOperatorOrOwner');
        _;
    }

    constructor(
        IMasterPlatypusV4 _MP,
        IERC20 _lpToken,
        uint256 _startTimestamp,
        IERC20 _rewardToken,
        uint96 _tokenPerSec
    ) {
        require(
            Address.isContract(address(_rewardToken)) || address(_rewardToken) == address(0),
            'constructor: reward token must be a valid contract'
        );
        require(Address.isContract(address(_lpToken)), 'constructor: LP token must be a valid contract');
        require(Address.isContract(address(_MP)), 'constructor: MasterPlatypus must be a valid contract');
        // require(_startTimestamp >= block.timestamp);

        MP = _MP;
        lpToken = _lpToken;

        lastRewardTimestamp = _startTimestamp;

        // use non-zero amount for accTokenPerShare as we want to check if user
        // has activated the pool by checking rewardDebt > 0
        PoolInfo memory pool = PoolInfo({rewardToken: _rewardToken, tokenPerSec: _tokenPerSec, accTokenPerShare: 1e18});
        poolInfo.push(pool);
        emit RewardRateUpdated(address(_rewardToken), 0, _tokenPerSec);
    }

    /// @notice Set operator address
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    function addRewardToken(IERC20 _rewardToken, uint96 _tokenPerSec) external onlyOwner {
        _updatePool();
        // use non-zero amount for accTokenPerShare as we want to check if user
        // has activated the pool by checking rewardDebt > 0
        PoolInfo memory pool = PoolInfo({rewardToken: _rewardToken, tokenPerSec: _tokenPerSec, accTokenPerShare: 1e18});
        poolInfo.push(pool);
        emit RewardRateUpdated(address(_rewardToken), 0, _tokenPerSec);
    }

    /// @dev This function should be called before lpSupply and sumOfFactors update
    function _updatePool() internal {
        uint256 length = poolInfo.length;
        uint256 lpSupply = lpToken.balanceOf(address(MP));

        if (block.timestamp > lastRewardTimestamp && lpSupply > 0) {
            for (uint256 i; i < length; ++i) {
                PoolInfo storage pool = poolInfo[i];
                uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * pool.tokenPerSec;
                pool.accTokenPerShare += toUint128((tokenReward * ACC_TOKEN_PRECISION) / lpSupply);
            }

            lastRewardTimestamp = block.timestamp;
        }
    }

    /// @notice Sets the distribution reward rate. This will also update the poolInfo.
    /// @param _tokenPerSec The number of tokens to distribute per second
    function setRewardRate(uint256 _tokenId, uint96 _tokenPerSec) external virtual onlyOperatorOrOwner {
        require(_tokenPerSec <= 10000e18, 'reward rate too high'); // in case of accTokenPerShare overflow
        _updatePool();

        uint256 oldRate = poolInfo[_tokenId].tokenPerSec;
        poolInfo[_tokenId].tokenPerSec = _tokenPerSec;

        emit RewardRateUpdated(address(poolInfo[_tokenId].rewardToken), oldRate, _tokenPerSec);
    }

    /// @notice Function called by MasterPlatypus whenever staker claims PTP harvest.
    /// @notice Allows staker to also receive a 2nd reward token.
    /// @dev Assume lpSupply and sumOfFactors isn't updated yet when this function is called
    /// @param _user Address of user
    /// @param _lpAmount The ORIGINAL amount of LP tokens the user has
    /// @param _newLpAmount The new amount of LP
    function onPtpReward(
        address _user,
        uint256 _lpAmount,
        uint256 _newLpAmount
    ) external virtual override onlyMP nonReentrant returns (uint256[] memory rewards) {
        _updatePool();

        uint256 length = poolInfo.length;
        rewards = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            PoolInfo storage pool = poolInfo[i];
            UserInfo storage user = userInfo[i][_user];
            IERC20 rewardToken = pool.rewardToken;

            // if user has activated the pool, update rewards
            if (user.rewardDebt > 0) {
                uint256 pending = ((_lpAmount * pool.accTokenPerShare) / ACC_TOKEN_PRECISION) +
                    user.claimable -
                    user.rewardDebt;

                if (address(rewardToken) == address(0)) {
                    // is native token
                    uint256 tokenBalance = address(this).balance;
                    if (pending > tokenBalance) {
                        (bool success, ) = _user.call{value: tokenBalance}('');
                        require(success, 'Transfer failed');
                        rewards[i] = tokenBalance;
                        user.claimable = toUint128(pending - tokenBalance);
                    } else {
                        (bool success, ) = _user.call{value: pending}('');
                        require(success, 'Transfer failed');
                        rewards[i] = pending;
                        user.claimable = 0;
                    }
                } else {
                    // ERC20 token
                    uint256 tokenBalance = rewardToken.balanceOf(address(this));
                    if (pending > tokenBalance) {
                        rewardToken.safeTransfer(_user, tokenBalance);
                        rewards[i] = tokenBalance;
                        user.claimable = toUint128(pending - tokenBalance);
                    } else {
                        rewardToken.safeTransfer(_user, pending);
                        rewards[i] = pending;
                        user.claimable = 0;
                    }
                }
            }

            user.rewardDebt = toUint128((_newLpAmount * pool.accTokenPerShare) / ACC_TOKEN_PRECISION);
            emit OnReward(address(rewardToken), _user, rewards[i]);
        }
    }

    /// @notice returns pool length
    function poolLength() external view override returns (uint256) {
        return poolInfo.length;
    }

    /// @notice View function to see pending tokens
    /// @param _user Address of user.
    /// @return rewards reward for a given user.
    function pendingTokens(address _user, uint256 _lpAmount) external view override returns (uint256[] memory rewards) {
        uint256 length = poolInfo.length;
        rewards = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            PoolInfo memory pool = poolInfo[i];
            UserInfo storage user = userInfo[i][_user];

            uint256 accTokenPerShare = pool.accTokenPerShare;
            uint256 lpSupply = lpToken.balanceOf(address(MP));

            if (block.timestamp > lastRewardTimestamp && lpSupply > 0) {
                uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * pool.tokenPerSec;
                accTokenPerShare += (tokenReward * ACC_TOKEN_PRECISION) / lpSupply;
            }

            rewards[i] = ((_lpAmount * accTokenPerShare) / ACC_TOKEN_PRECISION) - user.rewardDebt + user.claimable;
        }
    }

    /// @notice return an array of reward tokens
    function rewardTokens() external view override returns (IERC20[] memory tokens) {
        uint256 length = poolInfo.length;
        tokens = new IERC20[](length);
        for (uint256 i; i < length; ++i) {
            PoolInfo memory pool = poolInfo[i];
            tokens[i] = pool.rewardToken;
        }
    }

    /// @notice In case rewarder is stopped before emissions finished, this function allows
    /// withdrawal of remaining tokens.
    function emergencyWithdraw() external onlyOwner {
        uint256 length = poolInfo.length;

        for (uint256 i; i < length; ++i) {
            PoolInfo storage pool = poolInfo[i];
            if (address(pool.rewardToken) == address(0)) {
                // is native token
                (bool success, ) = msg.sender.call{value: address(this).balance}('');
                require(success, 'Transfer failed');
            } else {
                pool.rewardToken.safeTransfer(address(msg.sender), pool.rewardToken.balanceOf(address(this)));
            }
        }
    }

    /// @notice avoids loosing funds in case there is any tokens sent to this contract
    /// @dev only to be called by owner
    function emergencyTokenWithdraw(address token) external onlyOwner {
        // send that balance back to owner
        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    /// @notice View function to see balances of reward token.
    function balances() external view returns (uint256[] memory balances_) {
        uint256 length = poolInfo.length;
        balances_ = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            PoolInfo storage pool = poolInfo[i];
            if (address(pool.rewardToken) == address(0)) {
                // is native token
                balances_[i] = address(this).balance;
            } else {
                balances_[i] = pool.rewardToken.balanceOf(address(this));
            }
        }
    }

    /// @notice payable function needed to receive AVAX
    receive() external payable {}

    function toUint128(uint256 val) internal pure returns (uint128) {
        if (val > type(uint128).max) revert('uint128 overflow');
        return uint128(val);
    }
}
