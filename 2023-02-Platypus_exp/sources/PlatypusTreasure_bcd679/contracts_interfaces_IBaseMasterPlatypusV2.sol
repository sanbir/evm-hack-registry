// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/**
 * @dev Interface of the BaseMasterPlatypus, obtain PTP from voter
 */
interface IBaseMasterPlatypusV2 {
    function poolLength() external view returns (uint256);

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

    function updatePool(uint256 _pid) external;

    function massUpdatePools() external;

    function notifyRewardAmount(address token, uint256 amount) external;

    function deposit(uint256 _pid, uint256 _amount) external returns (uint256, uint256[] memory);

    function multiClaim(uint256[] memory _pids)
        external
        returns (
            uint256 reward,
            uint256[] memory amounts,
            uint256[][] memory additionalRewards
        );

    function withdraw(uint256 _pid, uint256 _amount) external returns (uint256, uint256[] memory);

    function emergencyWithdraw(uint256 _pid) external;

    function migrate(uint256[] calldata _pids) external;

    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) external;
}
