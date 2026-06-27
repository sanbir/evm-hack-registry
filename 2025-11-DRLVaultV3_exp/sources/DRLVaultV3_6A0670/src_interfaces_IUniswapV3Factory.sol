// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

interface IUniswapV3Factory {
    function getPool(address token0, address token1, uint24 _fee) external returns (address);
}
