// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import './IAsset.sol';
import './IBoostedMultiRewarder.sol';
import './IPlatypusTreasure.sol';

/**
 * @dev Interface of the MasterPlatypusV4
 */
interface IMasterPlatypusV4 {
    // Info of each user.
    struct UserInfo {
        // 256 bit packed
        uint128 amount; // How many LP tokens the user has provided.
        uint128 factor; // non-dialuting factor = sqrt (lpAmount * vePtp.balanceOf())
        // 256 bit packed
        uint128 rewardDebt; // Reward debt. See explanation below.
        uint128 claimablePtp;
        //
        // We do some fancy math here. Basically, any point in time, the amount of PTPs
        // entitled to a user but is pending to be distributed is:
        //
        //   ((user.amount * pool.accPtpPerShare + user.factor * pool.accPtpPerFactorShare) / 1e12) -
        //        user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accPtpPerShare`, `accPtpPerFactorShare` (and `lastRewardTimestamp`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IAsset lpToken; // Address of LP token contract.
        IBoostedMultiRewarder rewarder;
        uint128 sumOfFactors; // 20.18 fixed point. The sum of all non dialuting factors by all of the users in the pool
        uint128 accPtpPerShare; // 26.12 fixed point. Accumulated PTPs per share, times 1e12.
        uint128 accPtpPerFactorShare; // 26.12 fixed point. Accumulated ptp per factor share
    }

    function platypusTreasure() external view returns (IPlatypusTreasure);

    function getSumOfFactors(uint256) external view returns (uint256);

    function poolLength() external view returns (uint256);

    function getPoolId(address) external view returns (uint256);

    function getUserInfo(uint256 _pid, address _user) external view returns (UserInfo memory);

    function pendingTokens(uint256 _pid, address _user)
        external
        view
        returns (
            uint256 pendingPtp,
            IERC20[] memory bonusTokenAddresses,
            string[] memory bonusTokenSymbols,
            uint256[] memory pendingBonusTokens
        );

    function rewarderBonusTokenInfo(uint256 _pid)
        external
        view
        returns (IERC20[] memory bonusTokenAddresses, string[] memory bonusTokenSymbols);

    function massUpdatePools() external;

    function updatePool(uint256 _pid) external;

    function deposit(uint256 _pid, uint256 _amount)
        external
        returns (uint256 reward, uint256[] memory additionalRewards);

    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) external;

    function multiClaim(uint256[] memory _pids)
        external
        returns (
            uint256 reward,
            uint256[] memory amounts,
            uint256[][] memory additionalRewards
        );

    function withdraw(uint256 _pid, uint256 _amount)
        external
        returns (uint256 reward, uint256[] memory additionalRewards);

    function liquidate(
        uint256 _pid,
        address _user,
        uint256 _amount
    ) external;

    function emergencyWithdraw(uint256 _pid) external;

    function migrate(uint256[] calldata _pids) external;

    function updateFactor(address _user, uint256 _newVePtpBalance) external;

    function notifyRewardAmount(address _lpToken, uint256 _amount) external;
}
