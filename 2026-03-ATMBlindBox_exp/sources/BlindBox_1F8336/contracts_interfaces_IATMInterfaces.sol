// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IATMToken {
    function internalTransferFrom(address from, address to, uint256 amount) external;
    function usdt() external view returns (address);
    function pair() external view returns (address);
    function getPrice() external view returns (uint256 reserveATM, uint256 reserveUSDT);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function updateExitQuota(address user, uint256 amount) external;
}

interface IBlindBox {
    function onBlindBoxEntry(address user, uint256 amount, uint256 reserveATM, uint256 reserveUSDT) external returns (bool);
    function settle(address settler) external returns (bool);
}

interface IExitQueue {
    function onExitEntry(address user, uint256 amount, uint256 usdtValue) external returns (bool);
    function settleExits(uint256 availableUSDT) external returns (uint256 used);
    function getQueueHead(bool isSmall) external view returns (address user, uint256 usdtOwed);
    function queueLength(bool isSmall) external view returns (uint256);
    function hasPosition(address user) external view returns (bool);
    function onAccelerate(address user, uint256 usdtValue) external returns (uint256 refundATM);
}

interface ILottery {
    function onBuy(address user, uint256 usdtValue) external;
    function onSell(address user, uint256 usdtValue) external;
    function checkAndSettle() external returns (bool triggered);
    function injectP4(uint256 amount) external;
    function forceEndRound() external;
}
