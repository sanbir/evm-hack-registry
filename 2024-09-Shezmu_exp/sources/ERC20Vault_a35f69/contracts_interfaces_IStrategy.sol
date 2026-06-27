// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

interface IStrategy {
    error ZeroAmount();
    error ZeroAddress();
    error InvalidAmount();
    error InsufficientAmount();
    error Unauthorized();

    function deposit(
        address _account,
        uint _amount
    ) external returns (uint share);

    function withdraw(
        address _account,
        uint _shareAmount
    ) external returns (uint withdrawn);

    function getUnderlyingAmount(address _account) external view returns (uint);

    function toAmount(uint share) external view returns (uint);

    function pendingRewards(
        address _account
    ) external view returns (address[] memory, uint256[] memory);

    function claimRewards(address _account) external;
}
