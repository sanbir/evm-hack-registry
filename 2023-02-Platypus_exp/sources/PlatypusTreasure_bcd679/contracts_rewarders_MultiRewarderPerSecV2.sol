// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.14;

import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import './MultiRewarderPerSec.sol';

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
 * - Resets token per sec to zero if token balance cannot fullfill rewards that are due
 */
contract MultiRewarderPerSecV2 is MultiRewarderPerSec {
    using SafeERC20 for IERC20;

    constructor(
        IMasterPlatypusV4 _MP,
        IERC20 _lpToken,
        uint256 _startTimestamp,
        IERC20 _rewardToken,
        uint96 _tokenPerSec
    ) MultiRewarderPerSec(_MP, _lpToken, _startTimestamp, _rewardToken, _tokenPerSec) {}

    /// @notice Sets the distribution reward rate. This will also update the poolInfo.
    /// @param _tokenPerSec The number of tokens to distribute per second
    function setRewardRate(uint256 _tokenId, uint96 _tokenPerSec) external override onlyOperatorOrOwner {
        require(_tokenPerSec <= 10000e18, 'reward rate too high'); // in case of accTokenPerShare overflow
        _setRewardRate(_tokenId, _tokenPerSec);
    }

    function _setRewardRate(uint256 _tokenId, uint96 _tokenPerSec) internal {
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
    ) external override onlyMP nonReentrant returns (uint256[] memory rewards) {
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
                    if (pending >= tokenBalance) {
                        (bool success, ) = _user.call{value: tokenBalance}('');
                        require(success, 'Transfer failed');
                        rewards[i] = tokenBalance;
                        user.claimable = toUint128(pending - tokenBalance);
                        // In case partners forget to replenish token, pause token emission
                        // Note that some accumulated rewards might not be able to distribute
                        _setRewardRate(i, 0);
                    } else {
                        (bool success, ) = _user.call{value: pending}('');
                        require(success, 'Transfer failed');
                        rewards[i] = pending;
                        user.claimable = 0;
                    }
                } else {
                    // ERC20 token
                    uint256 tokenBalance = rewardToken.balanceOf(address(this));
                    if (pending >= tokenBalance) {
                        rewardToken.safeTransfer(_user, tokenBalance);
                        rewards[i] = tokenBalance;
                        user.claimable = toUint128(pending - tokenBalance);
                        // In case partners forget to replenish token, pause token emission
                        // Note that some accumulated rewards might not be able to distribute
                        _setRewardRate(i, 0);
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
}
