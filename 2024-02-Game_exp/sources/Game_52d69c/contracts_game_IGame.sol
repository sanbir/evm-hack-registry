// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IGame {
    function isStarted() external view returns (bool);

    function gameEndTime() external view returns (uint256);

    function isGameEnd() external view returns (bool);

    function isWriteEnable() external view returns (bool);

    function isAuction() external view returns (bool);

    function isAuctionEnd() external view returns (bool);

    function isNftClaimed() external view returns (bool);
}
