// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;
import {IPancakePair} from "./IPancakePair.sol";
import {IUniswapV2Factory} from "./IUniswapV2Factory.sol";
import {IPancakeRouter02} from "./IPancakeRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {_GPC, _ROUTER,_WBNB,_USDC,_USDT} from "./Const.sol";


contract Distributor {
    constructor() {
        IERC20(_GPC).approve(msg.sender, type(uint256).max);
    }
}

abstract contract BaseGpc {
    bool public inSwapAndLiquify;
    IPancakeRouter02 constant uniswapV2Router = IPancakeRouter02(_ROUTER);
    address public immutable uniswapV2Pair;
    Distributor public immutable distributor;
    mapping(address=>bool) pairs;


    modifier lockTheSwap() {
        require(inSwapAndLiquify != true, 'Cannot Reenter Swap');
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }
    constructor() {
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), _GPC);
        distributor = new Distributor();
        pairs[uniswapV2Pair]=true;
        address bnbPair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), _WBNB);
        address usdcPair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), _USDC);
        address usdtPair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), _USDT);
        pairs[bnbPair]=true;
        pairs[usdcPair]=true;
        pairs[usdtPair]=true;
    }

    function isPair(address account) public view returns (bool) {
        return pairs[account];
    }

    function isMainPair(address pair) public view returns (bool){
        return pair==uniswapV2Pair;
    }
}