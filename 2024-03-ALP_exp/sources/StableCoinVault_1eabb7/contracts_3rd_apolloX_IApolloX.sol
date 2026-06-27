// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IApolloX {
  function mintAlp(
    address tokenIn,
    uint256 amount,
    uint256 minAlp,
    bool stake
  ) external;

  function unStake(uint256 _amount) external;

  function burnAlp(
    address tokenOut,
    uint256 alpAmount,
    uint256 minOut,
    address receiver
  ) external;

  function stakeOf(address account) external view returns (uint256);

  function pendingApx(address _account) external view returns (uint256);

  function claimAllReward() external;
}
