// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "@size/src/market/libraries/Errors.sol";
import {I1InchAggregator} from "src/interfaces/dex/I1InchAggregator.sol";
import {IUniswapV2Router02} from "src/interfaces/dex/IUniswapV2Router02.sol";
import {IUniswapV3Router} from "src/interfaces/dex/IUniswapV3Router.sol";
import {IUnoswapRouter} from "src/interfaces/dex/IUnoswapRouter.sol";
import {PeripheryErrors} from "src/libraries/PeripheryErrors.sol";
import {BoringPtSeller} from "@pendle/contracts/oracles/PtYtLpOracle/samples/BoringPtSeller.sol";
import {IPMarket} from "@pendle/contracts/interfaces/IPMarket.sol";
import {IStandardizedYield} from "@pendle/contracts/interfaces/IStandardizedYield.sol";
import {
    createDefaultApproxParams,
    createTokenInputSimple,
    createEmptyLimitOrderData
} from "@pendle/contracts/interfaces/IPAllActionTypeV3.sol";
import {IPAllActionV3} from "@pendle/contracts/interfaces/IPAllActionV3.sol";

enum SwapMethod {
    OneInch,
    Unoswap,
    UniswapV2,
    UniswapV3,
    GenericRoute,
    BoringPtSeller,
    BuyPt
}

struct SwapParams {
    SwapMethod method;
    bytes data;
}

struct BoringPtSellerParams {
    address pt;
    address market;
    bool tokenOutIsYieldToken;
}

struct OneInchParams {
    address fromToken;
    address toToken;
    uint256 minReturn;
    bytes data;
}

struct UniswapV2Params {
    uint256 amountIn;
    uint256 amountOutMin;
    address[] path;
    address to;
    uint256 deadline;
}

struct UniswapV3Params {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    uint160 sqrtPriceLimitX96;
    uint256 amountOutMinimum;
}

struct UnoswapParams {
    address recipient;
    address srcToken;
    uint256 amount;
    uint256 minReturn;
    address pool;
}

struct BuyPtParams {
    address market;
    address tokenIn;
    address router;
    uint256 minPtOut;
}

struct GenericRouteParams {
    address router;
    address tokenIn;
    bytes data;
}

/// @title DexSwap
/// @custom:security-contact security@size.credit
/// @author Size (https://size.credit/)
/// @notice Contract that allows to swap tokens using different DEXs
abstract contract DexSwap is BoringPtSeller {
    using SafeERC20 for IERC20;

    I1InchAggregator public immutable oneInchAggregator;
    IUnoswapRouter public immutable unoswapRouter;
    IUniswapV2Router02 public immutable uniswapV2Router;
    IUniswapV3Router public immutable uniswapV3Router;

    constructor(
        address _oneInchAggregator,
        address _unoswapRouter,
        address _uniswapV2Router,
        address _uniswapV3Router
    ) {
        if (
            _oneInchAggregator == address(0) || _unoswapRouter == address(0) || _uniswapV2Router == address(0)
                || _uniswapV3Router == address(0)
        ) {
            revert Errors.NULL_ADDRESS();
        }

        oneInchAggregator = I1InchAggregator(_oneInchAggregator);
        unoswapRouter = IUnoswapRouter(_unoswapRouter);
        uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        uniswapV3Router = IUniswapV3Router(_uniswapV3Router);
    }

    function _swap(SwapParams[] memory swapParamsArray) internal {
        for (uint256 i = 0; i < swapParamsArray.length; i++) {
            _executeSwapStep(swapParamsArray[i]);
        }
    }

    function _executeSwapStep(SwapParams memory swapParams) internal {
        if (swapParams.method == SwapMethod.GenericRoute) {
            _swapGenericRoute(swapParams.data);
        } else if (swapParams.method == SwapMethod.OneInch) {
            _swap1Inch(swapParams.data);
        } else if (swapParams.method == SwapMethod.Unoswap) {
            _swapUnoswap(swapParams.data);
        } else if (swapParams.method == SwapMethod.UniswapV2) {
            _swapUniswapV2(swapParams.data);
        } else if (swapParams.method == SwapMethod.UniswapV3) {
            _swapUniswapV3(swapParams.data);
        } else if (swapParams.method == SwapMethod.BoringPtSeller) {
            _executePtSellerStep(swapParams.data);
        } else if (swapParams.method == SwapMethod.BuyPt) {
            _executeBuyPtStep(swapParams.data);
        } else {
            revert PeripheryErrors.INVALID_SWAP_METHOD();
        }
    }

    function _executePtSellerStep(bytes memory data) internal {
        BoringPtSellerParams memory params = abi.decode(data, (BoringPtSellerParams));
        address tokenOut = getPtSellerTokenOut(params.market, params.tokenOutIsYieldToken);
        _sellPtForToken(params.market, IERC20(params.pt).balanceOf(address(this)), tokenOut);
    }

    function _executeBuyPtStep(bytes memory data) internal {
        BuyPtParams memory params = abi.decode(data, (BuyPtParams));

        uint256 amountIn = IERC20(params.tokenIn).balanceOf(address(this));

        IERC20(params.tokenIn).forceApprove(params.router, amountIn);

        IPAllActionV3(params.router).swapExactTokenForPt(
            address(this),
            address(params.market),
            params.minPtOut,
            createDefaultApproxParams(),
            createTokenInputSimple(params.tokenIn, amountIn),
            createEmptyLimitOrderData()
        );
    }

    function _swap1Inch(bytes memory data) internal {
        OneInchParams memory params = abi.decode(data, (OneInchParams));
        IERC20(params.fromToken).forceApprove(address(oneInchAggregator), type(uint256).max);
        oneInchAggregator.swap(
            params.fromToken,
            params.toToken,
            IERC20(params.fromToken).balanceOf(address(this)),
            params.minReturn,
            params.data
        );
    }

    function _swapUniswapV2(bytes memory data) internal {
        UniswapV2Params memory params = abi.decode(data, (UniswapV2Params));
        IERC20(params.path[0]).forceApprove(address(uniswapV2Router), type(uint256).max);
        uniswapV2Router.swapExactTokensForTokens(
            params.amountIn, params.amountOutMin, params.path, params.to, params.deadline
        );
    }

    function _swapUnoswap(bytes memory data) internal {
        UnoswapParams memory params = abi.decode(data, (UnoswapParams));
        IERC20(params.srcToken).forceApprove(address(unoswapRouter), type(uint256).max);
        unoswapRouter.unoswapTo(address(this), params.srcToken, params.amount, params.minReturn, params.pool);
    }

    function _swapUniswapV3(bytes memory data) internal {
        UniswapV3Params memory params = abi.decode(data, (UniswapV3Params));
        uint256 amountIn = IERC20(params.tokenIn).balanceOf(address(this));
        IERC20(params.tokenIn).forceApprove(address(uniswapV3Router), amountIn);

        IUniswapV3Router.ExactInputSingleParams memory swapParams = IUniswapV3Router.ExactInputSingleParams({
            tokenIn: params.tokenIn,
            tokenOut: params.tokenOut,
            fee: params.fee,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: params.amountOutMinimum,
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });

        uniswapV3Router.exactInputSingle(swapParams);
    }

    function _swapGenericRoute(bytes memory data) internal {
        GenericRouteParams memory params = abi.decode(data, (GenericRouteParams));

        // Approve router to spend collateral token
        IERC20(params.tokenIn).forceApprove(params.router, type(uint256).max);

        // Execute swap via low-level call
        (bool success,) = params.router.call(params.data);
        if (!success) {
            revert PeripheryErrors.GENERIC_SWAP_ROUTE_FAILED();
        }
    }

    function getPtSellerTokenOut(address market, bool tokenOutIsYieldToken) public view returns (address) {
        (IStandardizedYield SY,,) = IPMarket(market).readTokens();
        address tokenOut;
        if (tokenOutIsYieldToken) {
            // PT (e.g. PT-sUSDE-29MAY2025) to yieldToken (e.g. sUSDe)
            tokenOut = SY.yieldToken();
        } else {
            // PT (e.g. PT-wstUSR-25SEP2025) to asset (e.g. USR)
            (, tokenOut,) = SY.assetInfo();
        }
        return tokenOut;
    }
}
