// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.19;

interface IControl {

    function mintProgressCount() external view returns (uint256);

    function redeemProgressCount() external view returns (uint256);

    function lastExecutedMint() external view returns (uint256);

    function lastExecutedRedeem() external view returns (uint256);

    function delegateApprove(address token, address guy, bool isApproved) external;

    function getDailyInitialMints() external view returns (uint256 startTime, uint256 endTime, uint256 amountUSD);

    function getInitialMints() external view returns (uint256 startTime, uint256 endTime, uint256 amountUSD);

    function initialMint() external payable;

    function getCurrentPrice() external view returns (uint256);

    function execute(uint8 argument) external;
}