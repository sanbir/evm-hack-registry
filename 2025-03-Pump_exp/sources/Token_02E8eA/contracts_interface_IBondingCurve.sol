// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

interface IBondingCurve {
    function getPrice(uint256 supply, uint256 amount) external pure returns (uint256);
    
    function getSellPrice(uint256 supply, uint256 amount) external pure returns (uint256);

    function getBuyPriceAfterFee(uint256 supply, uint256 amount) external view returns (uint256);

    function getSellPriceAfterFee(uint256 supply, uint256 amount) external view returns (uint256);

    function getBuyAmountByValue(uint256 bondingCurveSupply, uint256 ethAmount) external pure returns (uint256);
}