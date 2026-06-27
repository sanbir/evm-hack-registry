// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IBondStruct.sol";

interface IBondCalculator {
    function computeRoi(
        uint256 durationFromStart,
        uint256 totalDuration,
        IBondStruct.BondFunction composedFunction,
        uint256 totalTokenOut,
        uint256 amountTokenSold,
        uint256 gamma,
        uint256 scale,
        uint256 minRoi,
        uint256 maxRoi
    ) external pure returns (uint256 bondRoi);
}
