// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// DirectSwapExactAmountIn
import { BalancerV2SwapExactAmountIn } from "./swapExactAmountIn/direct/BalancerV2SwapExactAmountIn.sol";
import { CurveV1SwapExactAmountIn } from "./swapExactAmountIn/direct/CurveV1SwapExactAmountIn.sol";
import { CurveV2SwapExactAmountIn } from "./swapExactAmountIn/direct/CurveV2SwapExactAmountIn.sol";
import { UniswapV2SwapExactAmountIn } from "./swapExactAmountIn/direct/UniswapV2SwapExactAmountIn.sol";
import { UniswapV3SwapExactAmountIn } from "./swapExactAmountIn/direct/UniswapV3SwapExactAmountIn.sol";

// DirectSwapExactAmountOut
import { BalancerV2SwapExactAmountOut } from "./swapExactAmountOut/direct/BalancerV2SwapExactAmountOut.sol";
import { UniswapV2SwapExactAmountOut } from "./swapExactAmountOut/direct/UniswapV2SwapExactAmountOut.sol";
import { UniswapV3SwapExactAmountOut } from "./swapExactAmountOut/direct/UniswapV3SwapExactAmountOut.sol";

// Fees
import { AugustusFees } from "../fees/AugustusFees.sol";

// GenericSwapExactAmountIn
import { GenericSwapExactAmountIn } from "./swapExactAmountIn/GenericSwapExactAmountIn.sol";

// GenericSwapExactAmountOut
import { GenericSwapExactAmountOut } from "./swapExactAmountOut/GenericSwapExactAmountOut.sol";

// General
import { AugustusRFQRouter } from "./general/AugustusRFQRouter.sol";

// Utils
import { AugustusRFQUtils } from "../util/AugustusRFQUtils.sol";
import { BalancerV2Utils } from "../util/BalancerV2Utils.sol";
import { UniswapV2Utils } from "../util/UniswapV2Utils.sol";
import { UniswapV3Utils } from "../util/UniswapV3Utils.sol";
import { WETHUtils } from "../util/WETHUtils.sol";
import { Permit2Utils } from "../util/Permit2Utils.sol";

/// @title Routers
/// @notice A wrapper for all router contracts
contract Routers is
    AugustusFees,
    AugustusRFQRouter,
    BalancerV2SwapExactAmountOut,
    BalancerV2SwapExactAmountIn,
    CurveV1SwapExactAmountIn,
    CurveV2SwapExactAmountIn,
    GenericSwapExactAmountOut,
    GenericSwapExactAmountIn,
    UniswapV2SwapExactAmountOut,
    UniswapV2SwapExactAmountIn,
    UniswapV3SwapExactAmountOut,
    UniswapV3SwapExactAmountIn
{
    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _weth,
        uint256 _uniswapV3FactoryAndFF,
        uint256 _uniswapV3PoolInitCodeHash,
        uint256 _uniswapV2FactoryAndFF,
        uint256 _uniswapV2PoolInitCodeHash,
        address payable _balancerVault,
        address _permit2,
        address _rfq,
        address payable _feeVault
    )
        AugustusFees(_feeVault, _permit2)
        AugustusRFQUtils(_rfq)
        BalancerV2Utils(_balancerVault)
        Permit2Utils(_permit2)
        UniswapV2Utils(_uniswapV2FactoryAndFF, _uniswapV2PoolInitCodeHash, _permit2)
        UniswapV3Utils(_uniswapV3FactoryAndFF, _uniswapV3PoolInitCodeHash, _permit2)
        WETHUtils(_weth)
    { }
}
