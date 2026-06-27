// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IETHZapper {
    function swapExactTokensToETH(
        address tokenIn,
        uint tokenAmountIn,
        uint256 _amountOutMin,
        address amountReciever
    ) external;
}
