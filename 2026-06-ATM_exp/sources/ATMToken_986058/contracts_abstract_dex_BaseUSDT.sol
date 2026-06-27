// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IUniswapV2Factory} from "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {_USDT, _ROUTER} from "../../Const.sol";

address constant PinkLock02 = 0x407993575c91ce7643a4d4cCACc9A98c36eE1BBE;
address constant USDT = _USDT;

contract Distributor {
    constructor() {
        IERC20(_USDT).approve(msg.sender, type(uint256).max);
    }
}

abstract contract BaseUSDT {
    bool public inSwapAndLiquify;
    IUniswapV2Router02 constant uniswapV2Router = IUniswapV2Router02(_ROUTER);
    address public immutable uniswapV2Pair;
    Distributor public immutable distributor;

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor() {
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), USDT);
        distributor = new Distributor();
    }
}