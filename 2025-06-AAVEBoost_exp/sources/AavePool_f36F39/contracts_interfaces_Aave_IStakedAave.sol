// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStakedAave is IERC20 {
    function claimRewards(address to, uint256 amount) external;

    function getTotalRewardsBalance(address staker) external view returns (uint256);
}
