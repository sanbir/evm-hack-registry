// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./DynaVaultErrors.sol";
import "./interfaces/IMetaDynaRouterAPI.sol";
import "./interfaces/IDynaRouter.sol";
import "./interfaces/IDynaRouterRegistryAPI.sol";
import "./interfaces/IVaultManagerAPI.sol";
import "./utils/Checks.sol";
import "./VaultConfigLib.sol";

/**
 * @title DynaVault library
 * @notice VaultRouterLib is part of DynaVault
 * and is responsible for the estimating and executing token conversions by using a ReferenceAssetOracle and DynaRouterRegistry.
 * It contains logic to check oracle deviation when doing token conversion estimations to avoid flash-loan/sandwich style attacks.
 */
library VaultRouterLib {
	using Checks for address;
	using Math for uint256;
	using SafeERC20 for IERC20;

	event VaultSwapped(address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

	/**
	 * @notice Used to fetch swap data used when calling swap
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address fo the output token
	 * @return amountOut The expected amount out from the swap
	 * @return selectedRouter The address of the router to use
	 * @return swapData The swap data from the preview
	 */
	function previewSwap(
		address tokenIn,
		uint256 amountIn,
		address tokenOut
	) public view returns (uint256 amountOut, address selectedRouter, bytes32[] memory swapData) {
		address registry = VaultConfigLib.routerRegistry();
		IDynaRouterRegistryAPI.Route memory route = IDynaRouterRegistryAPI(registry).getDefaultPairRoute(tokenIn, tokenOut);
		(amountOut, selectedRouter, swapData) = IDynaRouterAPI(route.router).previewSwapRoute(tokenIn, amountIn, tokenOut, route.route);
	}

	/**
	 * @notice This a swap function to be called by vault management to swap and change target weights
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min expected amount out from swap
	 * @param swapData The swap data from the preview
	 */
	function _swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, address selectedRouter, bytes32[] memory swapData) private {
		address manager = VaultConfigLib.manager();
		IVaultManagerAPI(manager).checkManagementOrGovernance(msg.sender);
		address routerRegistry = VaultConfigLib.routerRegistry();
		if (!IDynaRouterRegistryAPI(routerRegistry).getEnabledRouter(selectedRouter)) {
			revert DynaVaultErrors.DynaRouterInactive(selectedRouter);
		}
		if (!IVaultManagerAPI(manager).tokenExists(tokenIn)) {
			revert DynaVaultErrors.DynaVaultSwapUnsupportedToken(tokenIn);
		}
		if (!IVaultManagerAPI(manager).tokenExists(tokenOut)) {
			revert DynaVaultErrors.DynaVaultSwapUnsupportedToken(tokenOut);
		}
		uint256 tokenInBalance = IERC20(tokenIn).balanceOf(address(this));
		if (tokenInBalance < amountIn) {
			revert DynaVaultErrors.DynaVaultSwapLackingAmountIn(tokenIn, amountIn, tokenInBalance);
		}
		uint256 allowed = IERC20(tokenIn).allowance(address(this), selectedRouter);
		if (allowed < amountIn) IERC20(tokenIn).safeIncreaseAllowance(selectedRouter, amountIn);
		uint256 tokenOutInitialBalance = IERC20(tokenOut).balanceOf(address(this));
		IDynaRouterAPI(selectedRouter).swap(tokenIn, amountIn, tokenOut, minAmountOut, address(this), swapData);
		uint256 _amountOut = IERC20(tokenOut).balanceOf(address(this)) - tokenOutInitialBalance;
		if (_amountOut < minAmountOut) {
			revert DynaVaultErrors.DynaVaultSwapSlippageProtection(tokenIn, amountIn, tokenOut, _amountOut, minAmountOut);
		}
		IVaultManagerAPI(manager).updateDebtAfterSwap(tokenIn, amountIn, tokenOut, _amountOut, true);
		emit VaultSwapped(msg.sender, tokenIn, tokenOut, amountIn, _amountOut);
	}

	/**
	 * @notice wrapper for the private swap function
	 * @notice this a swap function to be called by vault management to swap and change target weights
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min amount out expected from swap
	 * @param selectedRouter The address of router to use
	 * @param swapData The swap data from the preview
	 */
	function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, address selectedRouter, bytes32[] memory swapData) external {
		_swap(tokenIn, amountIn, tokenOut, minAmountOut, selectedRouter, swapData);
	}

	/**
	 * @notice Swap with reporting of all the tokens to ensure consistency
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min amount out expected from swap
	 * @param selectedRouter The address of router to use
	 * @param swapData The swap data from the preview
	 */
	function swapAndReport(
		address tokenIn,
		uint256 amountIn,
		address tokenOut,
		uint256 minAmountOut,
		address selectedRouter,
		bytes32[] memory swapData
	) external {
		IVaultManagerAPI(VaultConfigLib.manager()).reportAllReservesFromVault();
		_swap(tokenIn, amountIn, tokenOut, minAmountOut, selectedRouter, swapData);
	}

	/**
	 * @notice this a swap function to be called by the vault manager contract to rebalance, which does not change target depositDebtRatio weights
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min amount out expected from swap
	 * @return amountOut The amount of output token from swap
	 */
	function doSwap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut) external returns (uint256 amountOut) {
		VaultConfigLib.onlyManager();
		(, address router, bytes32[] memory swapData) = previewSwap(tokenIn, amountIn, tokenOut);
		uint256 allowed = IDynaRouterAPI(router).spenderAllowance(tokenIn);
		if (allowed < amountIn) IERC20(tokenIn).safeIncreaseAllowance(router, amountIn);
		uint256 tokenOutInitialBalance = IERC20(tokenOut).balanceOf(address(this));
		IDynaRouterAPI(router).swap(tokenIn, amountIn, tokenOut, minAmountOut, address(this), swapData);
		amountOut = IERC20(tokenOut).balanceOf(address(this)) - tokenOutInitialBalance;
		if (amountOut < minAmountOut) {
			revert DynaVaultErrors.DynaVaultSwapSlippageProtection(tokenIn, amountIn, tokenOut, amountOut, minAmountOut);
		}
		IVaultManagerAPI(VaultConfigLib.manager()).updateDebtAfterSwap(tokenIn, amountIn, tokenOut, amountOut, false);
	}
}
