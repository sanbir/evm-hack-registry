// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title PancakeLibrary interface
 */

interface IPancakeLibrary {

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(address factory, address tokenA, address tokenB) external view returns (address pair);

    // fetches and sorts the reserves for a pair
    function getReserves(address factory, address tokenA, address tokenB) external pure returns (uint reserveA, uint reserveB);

    // given some amount of an asset and pair reserves, returns an equivalent amount of the other asset
    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external view returns (uint amountOut);

    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);

    // performs chained getAmountOut calculations on any number of pairs
    function getAmountsOut(address factory, uint amountIn, address[] memory path) external view returns (uint[] memory amounts);

    // performs chained getAmountIn calculations on any number of pairs
    function getAmountsIn(address factory, uint amountOut, address[] memory path) external pure returns (uint[] memory amounts);
}