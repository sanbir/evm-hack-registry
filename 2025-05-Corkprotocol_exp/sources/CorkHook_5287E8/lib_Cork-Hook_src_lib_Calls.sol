pragma solidity ^0.8.20;

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-periphery/lib/v4-core/src/types/PoolKey.sol";

enum Action {
    AddLiquidity,
    RemoveLiquidity,
    Swap
}

struct AddLiquidtyParams {
    address token0;
    uint256 amount0;
    address token1;
    uint256 amount1;
    address sender;
}

struct RemoveLiquidtyParams {
    address token0;
    address token1;
    uint256 liquidityAmount;
    address sender;
}

struct SwapParams {
    // for flashswap
    bytes swapData;
    IPoolManager.SwapParams params;
    PoolKey poolKey;
    address sender;
    uint256 amountOut;
    uint256 amountIn;
}
