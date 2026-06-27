// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDiscountPolicy {

    function computeDiscountTokensToSpend(uint256 undiscountedFeeInUsd)
    external view returns (uint256 discountTokensToSpend, uint256 discountMultiplier);

    function discountToken() external view returns (address);
    function discountTokenRate() external view returns (uint256);
    function discountRate() external view returns (uint256);
    function decimals() external view returns (uint8);

    event DiscountTokenRateUpdated(uint256 indexed newDiscountRate);
    event DiscountRateUpdated(uint256 indexed newDiscountRate);

}
