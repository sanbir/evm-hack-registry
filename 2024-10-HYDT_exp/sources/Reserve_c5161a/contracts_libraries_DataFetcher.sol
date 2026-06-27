// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.19;

import "../interfaces/IPancakeFactory.sol";
import "../interfaces/IPancakePair.sol";

library DataFetcher {

    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (address pair) {
        require(tokenA != tokenB, "DataFetcher: IDENTICAL_ADDRESSES");
        require(tokenA != address(0) && tokenB != address(0), "DataFetcher: ZERO_ADDRESS_TOKEN");
        pair = IPancakeFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "DataFetcher: ZERO_ADDRESS_PAIR");
    }

    function getReserves(
        address factory,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        address pair = pairFor(factory, tokenA, tokenB);
        address token0 = IPancakePair(pair).token0();
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
        require(reserveA > 0 && reserveB > 0, "DataFetcher: INSUFFICIENT_LIQUIDITY");
    }

    function quote(
        address factory,
        uint256 amountA,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 amountB) {
        require(amountA > 0, "DataFetcher: INSUFFICIENT_AMOUNT");
        (uint256 reserveA, uint256 reserveB) = getReserves(factory, tokenA, tokenB);
        amountB = (amountA * reserveB) / reserveA;
    }

    function quoteBatch(
        address factory,
        uint256[] memory amountsA,
        address tokenA,
        address tokenB
    ) internal view returns (uint256[] memory amountsB) {
        require(amountsA.length >= 1, "DataFetcher: INVALID_AMOUNTS_A");
        (uint256 reserveA, uint256 reserveB) = getReserves(factory, tokenA, tokenB);
        amountsB = new uint256[](amountsA.length);

        for (uint256 i = 0 ; i < amountsA.length ; i++) {
            require(amountsA[i] > 0, "DataFetcher: INSUFFICIENT_AMOUNT");
            amountsB[i] = (amountsA[i] * reserveB) / reserveA;
        }
    }

    function quoteRouted(
        address factory,
        uint256 amountA,
        address[] memory path
    ) internal view returns (uint256 amountB) {
        require(amountA > 0, "DataFetcher: INSUFFICIENT_AMOUNT");
        require(path.length >= 2, "DataFetcher: INVALID_PATH");
        uint256[] memory amounts = new uint256[](path.length);
        amounts[0] = amountA;

        for (uint256 i = 0 ; i < path.length - 1 ; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = (amounts[i] * reserveOut) / reserveIn;
        }
        amountB = amounts[path.length - 1];
    }
}