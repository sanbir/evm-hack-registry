// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IDynaRouterRegistryAPI {
	struct Route {
		address router;
		bytes32[] route;
	}

	function allRouters(uint256 index) external view returns (address);

	function enabledRouters(uint256 index) external view returns (address);

	function getAllRouters() external view returns (address[] memory selectedRouters);

	function getEnabledRouter(address router) external view returns (bool isEnabled);

	function getEnabledRouters() external view returns (address[] memory selectedRouters);

	function getNativeRouters() external view returns (address[] memory selectedRouters);

	function getTokenRouter(address token, uint256 index) external view returns (address selectedRouter);

	function getTokenRouters(address token) external view returns (address[] memory selectedRouters);

	function getMultiTokenRouters() external view returns (address[] memory selectedRouters);

	function getPairRouter(address tokenIn, address tokenOut, uint256 index) external view returns (address selectedRouter);

	function getPairRouters(address tokenIn, address tokenOut) external view returns (address[] memory selectedRouters);

	function getPairRoutes(address tokenIn, address tokenOut) external view returns (Route[] memory selectedRoutes);

	function getDefaultNativeRouter() external view returns (address defaultRouter);

	function getDefaultTokenRouter(address token) external view returns (address defaultRouter);

	function getDefaultMultiTokenRouter() external view returns (address defaultRouter);

	function getDefaultPairRoute(address tokenIn, address tokenOut) external view returns (Route memory defaultRoute);

	function getDefaultPairRouter(address tokenIn, address tokenOut) external view returns (address defaultRouter);

	function setTokenRouters(address token, address[] memory newRouters) external;
}
