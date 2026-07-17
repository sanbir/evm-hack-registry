//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceStorage {
    struct PriceTime {
        uint256 price;
        uint256 timestamp;
    }
    event DailyOpenPrice(uint256 day, PriceTime openPrice);

    function getDailyOpenPrice(uint256 day) external view returns (PriceTime memory openPrice);
    function getLatestPrice() external view returns (PriceTime memory price);
    function calcCurrentPrice() external view returns (uint256 currentPrice);
    function getTodayOpenPrice() external view returns (PriceTime memory todayOpenPrice);
    function getPriceChange() external view returns (int256 priceChange);
}
