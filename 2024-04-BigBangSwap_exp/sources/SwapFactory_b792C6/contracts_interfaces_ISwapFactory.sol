// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISwapFactory {

    function initCodeHash() external view returns (bytes32);

    function feeTo() external view returns(address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);

    function allPairs(uint index) external view returns (address pair);

    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function swapFee() external view returns (uint256);

    function protocolFee() external view returns (uint256);

    function liquidityFee() external view returns(uint256);

    function sortTokens(address tokenA, address tokenB) external view returns (address token0, address token1);

    function pairFor(address tokenA, address tokenB) external view returns (address pair);

    function getReserves(address tokenA, address tokenB) external view returns (uint256 reserveA, uint256 reserveB);

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external view returns (uint256 amountB);

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, address token0, address token1) external view returns (uint256 amountOut);

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, address token0, address token1) external view returns (uint256 amountIn);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);

    function router() external view returns(address);
}