pragma solidity 0.8.20;

import {IFacadeOutput} from "./IFacadeOutput.sol";

interface IFacadeInput {

    /// @notice Struct containing data for a single token swap operation
    struct SwapData {
        /// @notice The address of the input token to be swapped
        address tokenIn; 
        /// @notice The amount of input tokens to swap
        uint amountIn; 
        /// @notice The minimum amount of output tokens expected from the swap
        uint amountOutMinimum;
    }

    function multiSwapInputRepay(
        uint marginAccountID, 
        address positionToken,
        address tokenOut, 
        SwapData[] memory swapsData, 
        IFacadeOutput.SwapOutputData[] memory swapOutputData,
        uint repayAmount
    ) external;

    function borrowSwapInput(
        uint marginAccountID, 
        address positionToken,
        address tokenIn, 
        address tokenOut, 
        uint amountIn, 
        uint amountOutMinimum
    ) external;

    function multiSwapInputRepayForSettle(
        uint marginAccountID, 
        address tokenOut, 
        SwapData[] memory swapsData,
        IFacadeOutput.SwapOutputData[] memory swapOutputData,
        uint repayAmount
    ) external;

    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint amountIn
    ) external returns (uint amountOut);
}