// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title DynaRouter API is a generalized router API for converting one ERC20 token into another
 * @notice each DynaRouter needs to implement these functions
 * there is an abstract BaseDynaRouter to facilitate this
 * The basic usage flow for executing a swap in any DynaRouter is:
 * 1. If the dynarouter supports encoding preview routes the user can optionally call an encodePreviewRoute function
 *    This encodePreviewRoute function is not part of this interface, because the arguments are dependant on the specific AMM
 *    This can encode a route of pools, fee of pool, volatile/stable pair or any data required to calculate a quote in the AMM
 *    The output of the encodePreviewRoute should however always be encoded as an array of bytes32
 * 2. call previewSwapRoute (with given encoded preview route) or previewSwap (which tries to build a default route for given tokens) which returns:
 *    - an expected amount out
 *    - a router (in most cases this return its own address, unless it is an aggregate router)
 *    - encoded swap data (typically this encodes the route of pools, fee of pool, voltatile/stable pair or any data required to swap)
 * 3. call spenderAllowance using the input token which returns:
 *    - the current allowed amount of input tokens that can be spend by router
 * 4. call to increases allowance of the router, when the current allowed amount is less than the amount you want to swap
 * 5. calculate the minimum amount out by applying the slippage to the expected amount out
 *    and call swap giving tokens, (minimum) amounts, selected router, source & destination of assets, encoded swapdata
 */
interface IDynaRouterAPI {
	function getSpender() external view returns (address);

	function spenderAllowance(address token) external view returns (uint256 allowed);

	function estimateConversion(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut);

	function previewSwap(
		address tokenIn,
		uint256 amountIn,
		address tokenOut
	) external view returns (uint256 amountOut, address router, bytes32[] memory swapData);

	function previewSwapRoute(
		address tokenIn,
		uint256 amountIn,
		address tokenOut,
		bytes32[] memory previewRoute
	) external view returns (uint256 amountOut, address router, bytes32[] memory swapData);

	function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, address to, bytes32[] memory swapData) external;
}
