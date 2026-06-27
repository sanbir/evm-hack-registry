// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import "./SafeMath.sol";
import "../swap/interfaces/IUniswapChecker.sol";

library UniswapV2Library {
    using SafeMath for uint256;

    function getAmountsOut(uint256 amountIn, address[] memory path, address[] memory pool) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;

        for (uint256 i; i < pool.length; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(path[i], path[i + 1], pool[i]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn.mul(997);
        uint256 numerator = amountInWithFee.mul(reserveOut);
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) 
    internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    function getReserves(address tokenA, address tokenB, address pool) 
    internal view returns (uint reserveA, uint reserveB) {
        (address token0,) = sortTokens(tokenA, tokenB);
        (uint reserve0, uint reserve1,) = IUniswapChecker(pool).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }
}