/**
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2020 defrost Protocol
 */
pragma solidity >=0.7.0 <0.8.0;
interface ISwapHelper {
    function WAVAX() external view returns (address);
    function swapExactTokens(
        address token0,
        address token1,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external payable returns (uint256 amountOut);
    function swapExactTokens_oracle(
        address token0,
        address token1,
        uint256 amountIn,
        uint256 slipRate,
        address to
    ) external payable returns (uint256 amountOut);
    function swapToken_exactOut(address token0,address token1,uint256 amountMaxIn,uint256 amountOut,address to) external returns (uint256);
    function swapToken_exactOut_oracle(address token0,address token1,uint256 amountOut,uint256 slipRate,address to) external returns (uint256);
    function getAmountIn(address token0,address token1,uint256 amountOut)external view returns (uint256);
    function getAmountOut(address token0,address token1,uint256 amountIn)external view returns (uint256);
}
