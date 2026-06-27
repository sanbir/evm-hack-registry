// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

interface IUniswapChecker {
    //Get v3 fee
    function fee() external view returns (uint24);

    function token0() external view returns (address);

    function token1() external view returns (address);

    //Get v2 reserve
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast); 
}