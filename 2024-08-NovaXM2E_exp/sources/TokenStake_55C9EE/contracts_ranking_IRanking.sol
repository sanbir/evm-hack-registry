// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IRanking {
    event UpdateRank(address indexed user, uint256 rank);
    event EarnCommission(address indexed user, uint256 rank, uint256 usdtValue, uint256 tokenValue);

    function payRankingCommission(address _wallet, uint256 _earnUsd) external;
    function addSaleValue(address _wallet, uint256 _saleUsd) external;
    function subSaleValue(address _wallet, uint256 _saleUsd) external;
}
