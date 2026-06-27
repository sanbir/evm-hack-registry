pragma solidity 0.8.20;

interface IPositionManagerERC20 {
    // VIEW FUNCTIONS //

    function getPositionValue(uint256 amountIn) external returns (uint amountOut);

    /**
     * @notice Returns the output amount for a given input amount using the current Uniswap path.
     * @param amountIn The input amount for which to quote the output value.
     * @return amountOut The quoted output amount.
     */
    function getInputPositionValue(uint256 amountIn) external returns (uint amountOut);

    /**
     * @notice Returns the input amount required to obtain a given output amount using the current Uniswap path.
     * @param amountOut The desired output amount for which to quote the input value.
     * @return amountIn The quoted input amount.
     */
    function getOutputPositionValue(uint256 amountOut) external returns (uint amountIn);

    function tokenInContract() external returns(address tokenInContract);

    function tokenOutContract() external returns(address tokenOutContract);

    // ONLY MODULAR_SWAP_ROUTER_ROLE FUNCTION //

    /**
     * @notice Executes a liquidation by swapping the specified input amount of tokens.
     * @dev This function can only be called by an account with the MODULAR_SWAP_ROUTER_ROLE.
     * @param amountIn The amount of input tokens to swap.
     * @return amountOut The amount of output tokens received.
     */
    function liquidate(uint256 amountIn) external returns(uint amountOut);

    /**
     * @notice Executes an input swap with a specified minimum output amount.
     * @dev This function can only be called by an account with the MODULAR_SWAP_ROUTER_ROLE.
     * @param amountIn The amount of input tokens to swap.
     * @param amountOutMinimum The minimum amount of output tokens to receive.
     * @return amountOut The amount of output tokens received.
     */
    function swapInput(uint amountIn, uint amountOutMinimum) external returns(uint amountOut);

    /**
     * @notice Executes an output swap for a specified output amount.
     * @dev This function can only be called by an account with the MODULAR_SWAP_ROUTER_ROLE.
     * @param amountOut The desired amount of output tokens.
     * @return amountIn The amount of input tokens spent.
     */    
    function swapOutput(uint amountOut) external returns(uint amountIn);
}
