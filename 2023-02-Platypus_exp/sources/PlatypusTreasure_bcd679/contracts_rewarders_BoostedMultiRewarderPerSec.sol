// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import '../interfaces/IMasterPlatypusV4.sol';
import '../interfaces/IBoostedMultiRewarder.sol';

interface IWAVAX {
    function deposit() external payable;
}

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
 * - Support boosted pool. The dilutingRepartition can be different from that of MasterPlatypusV4
 */
contract BoostedMultiRewarderPerSec is IBoostedMultiRewarder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant ACC_TOKEN_PRECISION = 1e12;
    /// @notice WAVAX address on mainnet
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

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
        uint128 accTokenPerShare; // 26.12 fixed point. Amount of reward token each LP token is worth. Times 1e12
        uint128 accTokenPerFactorShare; // 26.12 fixed point. Accumulated ptp per factor share. Time 1e12
    }

    /// @notice address of the operator
    /// @dev operator is able to set emission rate
    address public operator;

    uint40 public lastRewardTimestamp;
    uint16 public dilutingRepartition; // base: 1000

    /// @notice Info of the poolInfo.
    PoolInfo[] public poolInfo;
    /// @notice tokenId => UserInfo
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    event OnReward(address indexed rewardToken, address indexed user, uint256 amount);
    event RewardRateUpdated(address indexed rewardToken, uint256 oldRate, uint256 newRate);
    event UpdateEmissionRepartition(address indexed user, uint256 dilutingRepartition, uint256 nonDilutingRepartition);

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
        uint40 _startTimestamp,
        uint16 _dilutingRepartition,
        IERC20 _rewardToken,
        uint96 _tokenPerSec
    ) {
        require(_dilutingRepartition <= 1000, '_dilutingRepartition > 1000');
        require(
            Address.isContract(address(_rewardToken)) || address(_rewardToken) == address(0),
            'constructor: reward token must be a valid contract'
        );
        require(Address.isContract(address(_lpToken)), 'constructor: LP token must be a valid contract');
        require(Address.isContract(address(_MP)), 'constructor: MasterPlatypus must be a valid contract');
        // require(_startTimestamp >= block.timestamp);

        MP = _MP;
        lpToken = _lpToken;
        dilutingRepartition = _dilutingRepartition;

        lastRewardTimestamp = _startTimestamp;

        // use non-zero amount for accTokenPerShare and accTokenPerFactorShare as we want to check if user
        // has activated the pool by checking rewardDebt > 0
        PoolInfo memory pool = PoolInfo({
            rewardToken: _rewardToken,
            tokenPerSec: _tokenPerSec,
            accTokenPerShare: 1e18,
            accTokenPerFactorShare: 1e18
        });
        poolInfo.push(pool);
        emit RewardRateUpdated(address(_rewardToken), 0, _tokenPerSec);
    }

    /// @notice Set operator address
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
    }

    function addRewardToken(IERC20 _rewardToken, uint96 _tokenPerSec) external onlyOwner {
        _updatePool();
        // use non-zero amount for accTokenPerShare and accTokenPerFactorShare as we want to check if user
        // has activated the pool by checking rewardDebt > 0
        PoolInfo memory pool = PoolInfo({
            rewardToken: _rewardToken,
            tokenPerSec: _tokenPerSec,
            accTokenPerShare: 1e18,
            accTokenPerFactorShare: 1e18
        });
        poolInfo.push(pool);
        emit RewardRateUpdated(address(_rewardToken), 0, _tokenPerSec);
    }

    /// @notice updates emission repartition
    /// @param _dilutingRepartition the future dialuting repartition
    function updateEmissionRepartition(uint16 _dilutingRepartition) external onlyOwner {
        require(_dilutingRepartition <= 1000);
        _updatePool();
        dilutingRepartition = _dilutingRepartition;
        emit UpdateEmissionRepartition(msg.sender, _dilutingRepartition, 1000 - _dilutingRepartition);
    }

    function _updatePool() internal {
        uint256 lpSupply = lpToken.balanceOf(address(MP));
        uint256 pid = MP.getPoolId(address(lpToken));
        uint256 sumOfFactors = MP.getSumOfFactors(pid);
        uint256 length = poolInfo.length;

        if (block.timestamp > lastRewardTimestamp && lpSupply > 0) {
            for (uint256 i; i < length; ++i) {
                PoolInfo storage pool = poolInfo[i];
                uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * pool.tokenPerSec;
                pool.accTokenPerShare += toUint128(
                    (tokenReward * ACC_TOKEN_PRECISION * dilutingRepartition) / lpSupply / 1000
                );
                if (sumOfFactors > 0) {
                    pool.accTokenPerFactorShare += toUint128(
                        (tokenReward * ACC_TOKEN_PRECISION * (1000 - dilutingRepartition)) / sumOfFactors / 1000
                    );
                }
            }

            lastRewardTimestamp = uint40(block.timestamp);
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
    /// @param _lpAmount Number of LP tokens the user has
    function onPtpReward(
        address _user,
        uint256 _lpAmount,
        uint256 _newLpAmount,
        uint256 _factor,
        uint256 _newFactor
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
                uint256 pending = ((_lpAmount * pool.accTokenPerShare + _factor * pool.accTokenPerFactorShare) /
                    ACC_TOKEN_PRECISION) +
                    user.claimable -
                    user.rewardDebt;

                if (address(rewardToken) == address(0)) {
                    // is native token
                    uint256 tokenBalance = address(this).balance;
                    if (pending > tokenBalance) {
                        _safeTransferAvaxWithFallback(_user, tokenBalance);
                        rewards[i] = tokenBalance;
                        user.claimable = toUint128(pending - tokenBalance);
                    } else {
                        _safeTransferAvaxWithFallback(_user, pending);
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

            user.rewardDebt = toUint128(
                (_newLpAmount * pool.accTokenPerShare + _newFactor * pool.accTokenPerFactorShare) / ACC_TOKEN_PRECISION
            );
            emit OnReward(address(rewardToken), _user, rewards[i]);
        }
    }

    /// @notice Function called by MasterPlatypus when factor is updated
    /// @dev Assume lpSupply and sumOfFactors isn't updated yet when this function is called
    /// @notice user.claimable will be updated
    function onUpdateFactor(
        address _user,
        uint256 _lpAmount,
        uint256 _factor,
        uint256 _newFactor
    ) external override onlyMP {
        if (dilutingRepartition == 1000) {
            // dialuting reard only
            return;
        }

        _updatePool();
        uint256 length = poolInfo.length;

        for (uint256 i; i < length; ++i) {
            PoolInfo storage pool = poolInfo[i];
            UserInfo storage user = userInfo[i][_user];

            // if user has active the pool
            if (user.rewardDebt > 0) {
                user.claimable += toUint128(
                    ((_lpAmount * pool.accTokenPerShare + _factor * pool.accTokenPerFactorShare) /
                        ACC_TOKEN_PRECISION) - user.rewardDebt
                );
            }

            user.rewardDebt = toUint128(
                (_lpAmount * pool.accTokenPerShare + _newFactor * pool.accTokenPerFactorShare) / ACC_TOKEN_PRECISION
            );
        }
    }

    /// @notice returns pool length
    function poolLength() external view override returns (uint256) {
        return poolInfo.length;
    }

    /// @notice View function to see pending tokens
    /// @param _user Address of user.
    /// @return rewards reward for a given user.
    function pendingTokens(
        address _user,
        uint256 _lpAmount,
        uint256 _factor
    ) external view override returns (uint256[] memory rewards) {
        uint256 lpSupply = lpToken.balanceOf(address(MP));
        uint256 pid = MP.getPoolId(address(lpToken));
        uint256 sumOfFactors = MP.getSumOfFactors(pid);
        uint256 length = poolInfo.length;

        rewards = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            PoolInfo memory pool = poolInfo[i];
            UserInfo storage user = userInfo[i][_user];

            uint256 accTokenPerShare = pool.accTokenPerShare;
            uint256 accTokenPerFactorShare = pool.accTokenPerFactorShare;

            if (block.timestamp > lastRewardTimestamp && lpSupply > 0) {
                uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
                uint256 tokenReward = timeElapsed * pool.tokenPerSec;
                accTokenPerShare += (tokenReward * ACC_TOKEN_PRECISION * dilutingRepartition) / lpSupply / 1000;
                if (sumOfFactors > 0) {
                    accTokenPerFactorShare +=
                        (tokenReward * ACC_TOKEN_PRECISION * (1000 - dilutingRepartition)) /
                        sumOfFactors /
                        1000;
                }
            }

            uint256 temp = _lpAmount * accTokenPerShare + _factor * accTokenPerFactorShare;
            rewards[i] = (temp / ACC_TOKEN_PRECISION) - user.rewardDebt + user.claimable;
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

    /**
     * @notice Transfer Avax. If the Avax transfer fails, wrap the Avax and try send it as WAVAX.
     */
    function _safeTransferAvaxWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferAvax(to, amount)) {
            IWAVAX(WAVAX).deposit{value: amount}();
            IERC20(WAVAX).transfer(to, amount);
        }
    }

    /**
     * @notice Transfer Avax and return the success status.
     * @dev This function only forwards 30,000 gas to the callee.
     */
    function _safeTransferAvax(address to, uint256 value) internal returns (bool) {
        (bool success, ) = to.call{value: value, gas: 30_000}(new bytes(0));
        return success;
    }
}
