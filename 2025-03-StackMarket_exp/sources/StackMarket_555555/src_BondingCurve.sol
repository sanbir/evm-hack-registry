// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

library BondingCurve {
    using FixedPointMathLib for uint256;

    error InsufficientLiquidity();

    // y = A(x^2)/B
    uint256 public constant A = 8; // 24 / 3
    uint256 public constant B = 100_000_000_000_000_000_000_000_000_000_000_000_000 ether;

    function getEthSellQuote(uint256 x0, uint256 ethOrderSize) external pure returns (uint256) {
        uint256 x0_cubed = x0 * x0 * x0;

        // calculate x0^3 - 3*dy*b/a
        uint256 diff = ethOrderSize.fullMulDiv(B, A);
        if (diff > x0_cubed) revert InsufficientLiquidity();

        uint256 x1 = FixedPointMathLib.cbrt(x0_cubed - diff);

        return x0 - x1;
    }

    function getTokenSellQuote(uint256 x0, uint256 tokensToSell) external pure returns (uint256) {
        if (x0 < tokensToSell) revert InsufficientLiquidity();
        uint256 x1 = x0 - tokensToSell;

        uint256 x1_cubed = x1 * x1 * x1;
        uint256 x0_cubed = x0 * x0 * x0;

        // calculate deltaY = (a/b)*(x1^3-x1^2)
        return (x0_cubed - x1_cubed).fullMulDiv(A, B);
    }

    function getEthBuyQuote(uint256 x0, uint256 ethOrderSize) external pure returns (uint256) {
        uint256 x0_cubed = x0;
        if (x0 > 0) {
            x0_cubed = x0 * x0 * x0;
        }
        // calculate x0^3 + 3*dy*b/a
        uint256 x1_cubed = x0_cubed + ethOrderSize.fullMulDiv(B, A);

        return FixedPointMathLib.cbrt(x1_cubed) - x0;
    }

    function getTokenBuyQuote(uint256 x0, uint256 tokenOrderSize) external pure returns (uint256) {
        uint256 x1 = tokenOrderSize + x0;

        uint256 x0_cubed = x0 * x0 * x0;
        uint256 x1_cubed = x1 * x1 * x1;

        return (x1_cubed - x0_cubed).fullMulDiv(A, B);
    }
}
