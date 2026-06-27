// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ISwapRouter {
    function factory() external view returns(address);

    function stakingFactory() external view returns(address);

    function WETH() external view returns(address);

    function baseTokenOf(address pair) external view returns(address);

    function isWhiteList(address pair,address account) external view returns(bool);

    function setWhiteList(address pair,address account,bool status) external;

    function takeToken(address pair, address token, uint256 amount) external;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}
