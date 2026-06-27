// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {BaseUSDT, USDT} from "./BaseUSDT.sol";
import {IUniswapV2Pair} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

abstract contract BaseUSDTWA is BaseUSDT {
    constructor() {
        require(USDT < address(this), "vd");
    }

    function _isAddLiquidity() internal view returns (bool isAdd) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapV2Pair);
        (uint256 r0,,) = mainPair.getReserves();
        uint256 bal = IUniswapV2Pair(USDT).balanceOf(address(mainPair));
        isAdd = bal >= (r0 + 1 ether);
    }

    function _isRemoveLiquidity() internal view returns (bool isRemove) {
        IUniswapV2Pair mainPair = IUniswapV2Pair(uniswapV2Pair);
        (uint256 r0,,) = mainPair.getReserves();
        uint256 bal = IUniswapV2Pair(USDT).balanceOf(address(mainPair));
        isRemove = r0 > bal;
    }
}