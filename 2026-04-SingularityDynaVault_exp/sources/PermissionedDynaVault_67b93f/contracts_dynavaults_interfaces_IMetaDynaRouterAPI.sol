// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IMetaDynaRouterAPI {
	struct Connector {
		address tokenOut;
		address router;
		bytes32[] route;
	}

	function routerRegistry() external view returns (address);

	function estimateConversion(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut);

	function estimateConversionNative(address tokenIn, uint256 amountIn, address tokenOut) external view returns (uint256 amountOut);

	function estimateConversionMulti(
		address[] memory tokensIn,
		uint256[] memory amountsIn,
		address[] memory tokensOut
	) external view returns (uint256[] memory amountsOut);

	function estimateConversionConnectors(address tokenIn, uint256 amountIn, Connector[] memory connectors) external view returns (uint256 amountOut);

	function previewSwap(
		address tokenIn,
		uint256 amountIn,
		address tokenOut
	) external view returns (uint256 amountOut, address router, bytes32[] memory swapData);

	function previewSwapNative(
		address tokenIn,
		uint256 amountIn,
		address tokenOut
	) external view returns (uint256 amountOut, address router, bytes32[] memory swapData);

	function previewSwapMulti(
		address[] memory tokensIn,
		uint256[] memory amountsIn,
		address[] memory tokensOut
	) external view returns (uint256[] memory amountsOut, address router, bytes32[] memory swapData);

	function previewSwapConnectors(
		address tokenIn,
		uint256 amountIn,
		Connector[] memory connectors
	) external view returns (uint256 amountOut, bytes32[][] memory swapDataList);

	function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, address router, address to, bytes32[] memory swapData) external;

	function swapNative(
		address tokenIn,
		uint256 amountIn,
		address tokenOut,
		uint256 minAmountOut,
		address router,
		address to,
		bytes32[] memory swapData
	) external payable;

	function swapMulti(
		address[] memory tokensIn,
		uint256[] memory amountsIn,
		address[] memory tokensOut,
		uint256[] memory minAmountsOut,
		address router,
		address to,
		bytes32[] memory swapData
	) external;

	function swapConnectors(
		address tokenIn,
		uint256 amountIn,
		Connector[] memory connectors,
		uint256[] memory minAmountsOut,
		address to,
		bytes32[][] memory swapDataList
	) external payable;
}
