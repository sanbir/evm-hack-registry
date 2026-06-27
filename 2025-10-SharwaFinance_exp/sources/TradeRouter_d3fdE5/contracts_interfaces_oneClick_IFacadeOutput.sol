pragma solidity 0.8.20;

interface IFacadeOutput {

    /// @notice Struct containing data for a single token swap output operation
    struct SwapOutputData {
        /// @notice The address of the input token to be swapped
        address tokenIn; 
        /// @notice The amount of output tokens to receive from the swap
        uint amountOut; 
        /// @notice The maximum amount of input tokens allowed for the swap
        uint amountInMaximum;
    }

    function multiSwapOutputRepay(
        uint marginAccountID, 
        address positionToken,
        address tokenOut, 
        SwapOutputData[] memory swapsData, 
        uint repayAmount
    ) external;

    function getAmountIn(
        address tokenIn,
        address tokenOut,
        uint amountOut
    ) external returns (uint amountIn);

    function borrowSwapOutput(
        uint marginAccountID, 
        address positionToken,
        address tokenIn, 
        address tokenOut, 
        uint amountOut
    ) external;
}