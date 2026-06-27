// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library DynaVaultErrors {
	// Vault Lib
	error MaxMint();
	error MaxDeposit();
	error MinDeposit();
	error MaxRedeem();
	error MinRedeem();
	error MaxWithdraw();
	error MinWithdraw();
	error StrategyLossProtection(uint256 toWithdraw, uint256 totalLoss, uint256 maxLoss);
	error ArrayMismatch();
	error ZeroShares();

	// Vault Token Lib
	error MaxTokens();
	error AmountInMoreThanTokenIdle(uint256 amountIn, address tokenIn, uint256 tokenIdle);
	error TokenIdle();
	error TokenDebt();
	error ERC20InsufficientBalance();
	error ERC20InsufficientAllowance();
	error InvalidToken();
	error MaxWatermarkDuration();

	// Vault Strategies Lib
	error UnableToChangeDebtRatioOnRevokedStrategy();

	// Vault Lib
	error MinAboveMax();
	error MaxTotalAssets();

	// Vault Config Lib
	error MaxLossLimit();
	error NotSameReferenceAsset();

	// Registry
	error NotRegistered(); // liq reg, vault reg
	error AlreadyRegistered(); // liq reg, vault reg , tokens lib

	// Vault Manager Lib
	error UpdateFeeOverTimeLimit();
	error IncorrectStrategyReport(uint256 strategyBalance, uint256 reportedGain, uint256 reportedDebtPayment);
	error LockedProfitDegradationCoefficient(uint256 newCoefficient, uint256 minimumCoefficient, uint256 maximumCoefficient);

	// Vault Router Lib
	error DynaVaultSwapUnsupportedToken(address token);
	error DynaVaultSwapLackingAmountIn(address tokenIn, uint256 amountIn, uint256 tokenInBalance);
	error DynaVaultSwapSlippageProtection(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, uint256 minAmountOut);
	error DynaRouterInactive(address router);

	// Config Lib, Gov Lib, Base Strategy, Vault
	error NotAuthorized();

	// Errors Lib
	error ERC5143_SlippageProtection();

	function checkSlippageBelow(uint256 value, uint256 maxValue) internal pure {
		if (value > maxValue) revert ERC5143_SlippageProtection();
	}

	function checkSlippageAbove(uint256 value, uint256 minValue) internal pure {
		if (value < minValue) revert ERC5143_SlippageProtection();
	}

	function checkSlippageAbove(uint256[] memory values, uint256[] memory minValues) internal pure {
		if (values.length != minValues.length) revert ArrayMismatch();
		for (uint256 i = 0; i < values.length; ++i) {
			checkSlippageAbove(values[i], minValues[i]);
		}
	}
}
