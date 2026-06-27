// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICvxLocker {
    struct EarnedData {
        IERC20 token;
        uint256 amount;
    }

    function lock(address _account, uint256 _amount, uint256 _spendRatio) external;

    function getReward(address _account) external;

    function claimableRewards(address _account) external view returns (EarnedData[] memory);
}
