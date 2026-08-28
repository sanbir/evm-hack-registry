// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface ISwap {
    event Swapped(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    function quote(uint256 amount, address tokenIn, address tokenOut) external returns (uint256);
    function swap(uint256 amount, uint256 minSwapAmount, address recipient, address tokenIn, address tokenOut)
        external
        payable
        returns (uint256);
}
