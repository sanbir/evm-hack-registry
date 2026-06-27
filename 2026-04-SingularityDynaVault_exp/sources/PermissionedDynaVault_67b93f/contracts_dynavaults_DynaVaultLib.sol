// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "solady/src/utils/FixedPointMathLib.sol";
import "./interfaces/IDynaStrategyAPI.sol";
import "./interfaces/IDynaRouterAPI.sol";
import "./interfaces/IVaultManagerAPI.sol";
import "./interfaces/IReferenceAssetOracle.sol";
import "./utils/Checks.sol";
import "./VaultConfigLib.sol";
import "./VaultRouterLib.sol";
import "./DynaVaultErrors.sol";

/**
 * @title DynaVault library
 * @notice Contains logic to implement EIP4626, EIP5143 vault standards including our redeemProportional extensions.
 * https://eips.ethereum.org/EIPS/eip-4626
 * https://eips.ethereum.org/EIPS/eip-5143
 */
library DynaVaultLib {
	using Checks for address;
	using FixedPointMathLib for uint256;
	using SafeERC20 for IERC20;

	/// @dev The storage slot follows EIP1967 to avoid storage collision
	bytes32 private constant VAULT_STORAGE_POSITION = bytes32(uint256(keccak256("DynaVault.VaultStorage")) - 1);
	address private constant ZERO_ADDRESS = address(0);
	uint256 private constant DEFAULT_MAX_TOTAL_ASSETS = type(uint256).max >> 64;
	uint256 private constant MAX_BPS = 100e2;
	uint256 private constant PRECISION = 1e18;
	uint8 private constant FEE_CALC_ITERATIONS = 10;

	struct VaultStorage {
		uint256 depositPrecision;
		uint256 minDepositAssets /* Minimum depositAmount in assets a user can deposit */;
		uint256 maxTotalAssets /* Limit for totalAssets the Vault can hold */;
	}

	event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
	event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
	event WithdrawFromStrategy(address strategy, uint256 strategyTotalDebt, uint256 loss);
	event DepositLimits(uint256 minDepositAssets, uint256 maxTotalAssets);

	/**
	 * @notice Returns the vault storage
	 * @return vs Storage pointer for accessing the state variables
	 */
	function vaultStorage() private pure returns (VaultStorage storage vs) {
		bytes32 position = VAULT_STORAGE_POSITION;
		assembly {
			vs.slot := position
		}
	}

	/** @notice Initializes the dyna vault library */
	function initialize() external {
		VaultStorage storage _storage = vaultStorage();
		if (_storage.maxTotalAssets != 0) {
			revert Checks.AlreadyInitialized();
		}
		_storage.depositPrecision = 10 ** VaultConfigLib.depositDecimals();
		_storage.maxTotalAssets = DEFAULT_MAX_TOTAL_ASSETS;
	}

	/**
	 * @notice Returns the vault manager API for interactions
	 * @return vaultManagerAPI Vault manager API instance that can be used for interactions
	 */
	function _manager() private view returns (IVaultManagerAPI) {
		return IVaultManagerAPI(VaultConfigLib.manager());
	}

	/**
	 * @notice Returns the address of the deposit token
	 * @return asset The address of the deposit token
	 */
	function _asset() private view returns (address) {
		return VaultConfigLib.asset();
	}

	/**
	 * @notice Returns the total value of the vault tokens in deposit token
	 * @return total The total value of vault tokens in deposit token
	 */
	function totalAssets() internal view returns (uint256 total) {
		total = _manager().totalAssets();
	}

	/**
	 * @notice Private function that calculates the value of shares in assets given total supply
	 * @param shares The amount of shares
	 * @param givenTotalSupply  The total shares supply to use in calculation
	 * @param rounding Specify to round up or down
	 * @return assets value of shares in assets
	 */
	function _convertToAssetsGivenTotalSupply(uint256 shares, uint256 givenTotalSupply, Math.Rounding rounding) private view returns (uint256 assets) {
		if (shares == 0) return 0;
		uint256 _freeFunds = _manager().freeFunds();
		if (givenTotalSupply == 0) {
			return _fullMulDiv(shares, vaultStorage().depositPrecision, PRECISION, rounding);
		} else {
			return _fullMulDiv(shares, _freeFunds, givenTotalSupply, rounding);
		}
	}

	/**
	 * @notice Private function that calculates the value of shares in assets given total supply
	 * @param shares The amount of shares
	 * @param givenTotalSupply  The total shares supply to use in calculation
	 * @param givenFreeFunds The total free funds
	 * @param rounding Specify to round up or down
	 * @return assets value of shares in assets
	 */
	function _convertToAssetsGivenTotalSupplyAndFreeFunds(
		uint256 shares,
		uint256 givenTotalSupply,
		uint256 givenFreeFunds,
		Math.Rounding rounding
	) private view returns (uint256 assets) {
		if (shares == 0) return 0;
		if (givenTotalSupply == 0) return _fullMulDiv(shares, vaultStorage().depositPrecision, PRECISION, rounding);
		return _fullMulDiv(shares, givenFreeFunds, givenTotalSupply, rounding);
	}

	/**
	 * @dev Do high precision multiplication and division with a specified rounding direction
	 * @notice Always round down towards the user and up towards the protocol to avoid exploitation
	 */
	function _fullMulDiv(uint256 x, uint256 y, uint256 z, Math.Rounding rounding) private pure returns (uint256) {
		if (rounding == Math.Rounding.Up) {
			return x.fullMulDivUp(y, z);
		} else {
			return x.fullMulDiv(y, z);
		}
	}

	/**
	 * @notice Converts assets to shares
	 * @param shares The amount of shares to convert
	 * @param rounding Specify to round up or down
	 * @return assets value of shares in assets
	 */
	function convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256 assets) {
		uint256 givenTotalSupply = totalSupply();
		assets = _convertToAssetsGivenTotalSupply(shares, givenTotalSupply, rounding);
	}

	/**
	 * @notice Private function that calculates the value of assets in shares given total supply
	 * @param assets The amount of assets
	 * @param givenTotalSupply The total shares supply to use in calculation
	 * @param rounding Specify to round up or down
	 * @return shares The value of assets in shares
	 */
	function _convertToSharesGivenTotalSupply(uint256 assets, uint256 givenTotalSupply, Math.Rounding rounding) private view returns (uint256 shares) {
		if (assets == 0) return 0;
		uint256 _freeFunds = _manager().freeFunds();
		if (givenTotalSupply == 0 || _freeFunds == 0) {
			return _fullMulDiv(assets, PRECISION, vaultStorage().depositPrecision, rounding);
		} else {
			return _fullMulDiv(assets, givenTotalSupply, _freeFunds, rounding);
		}
	}

	/**
	 * @notice Private function that calculates the value of assets in shares given total supply
	 * @param assets The amount of assets
	 * @param givenTotalSupply The total shares supply to use in calculation
	 * @param givenFreeFunds The total free funds
	 * @param rounding Specify to round up or down
	 * @return shares The value of assets in shares
	 */
	function _convertToSharesGivenTotalSupplyAndFreeFunds(
		uint256 assets,
		uint256 givenTotalSupply,
		uint256 givenFreeFunds,
		Math.Rounding rounding
	) private view returns (uint256 shares) {
		if (assets == 0) return 0;
		if (givenTotalSupply == 0 || givenFreeFunds == 0) return _fullMulDiv(assets, PRECISION, vaultStorage().depositPrecision, rounding);
		return _fullMulDiv(assets, givenTotalSupply, givenFreeFunds, rounding);
	}

	/**
	 * @notice Converts assets to shares
	 * @param assets The amount of assets to convert
	 * @return shares The value of assets in shares
	 */
	function convertToShares(uint256 assets) internal view returns (uint256 shares) {
		return _convertToSharesGivenTotalSupply(assets, totalSupply(), Math.Rounding.Up);
	}

	/** @notice Returns the total supply of shares */
	function totalSupply() private view returns (uint256) {
		return IERC20(address(this)).totalSupply();
	}

	/**
	 * @notice Set deposit limits
	 * @param newMinDepositAssets The new minimum deposit amount limit
	 * @param newMaxTotalAssets The new max total assets limit
	 */
	function setDepositLimits(uint256 newMinDepositAssets, uint256 newMaxTotalAssets) external {
		IVaultManagerAPI manager = _manager();
		manager.checkGovernance(msg.sender);
		// avoid maxMint from overflowing on convertToAssets
		if (newMaxTotalAssets > DEFAULT_MAX_TOTAL_ASSETS || newMaxTotalAssets == 0) revert DynaVaultErrors.MaxTotalAssets();
		if (newMinDepositAssets >= newMaxTotalAssets) revert DynaVaultErrors.MinAboveMax();
		vaultStorage().minDepositAssets = newMinDepositAssets;
		vaultStorage().maxTotalAssets = newMaxTotalAssets;
		emit DepositLimits(newMinDepositAssets, newMaxTotalAssets);
	}

	/** @notice Returns the minimum amount possible to deposit */
	function minDepositLimit() external view returns (uint256) {
		return vaultStorage().minDepositAssets;
	}

	/** @notice Returns the max amount possible to deposit */
	function maxDepositLimit() internal view returns (uint256 limit) {
		if (vaultStorage().maxTotalAssets > totalAssets()) {
			return vaultStorage().maxTotalAssets - totalAssets();
		}
	}

	/** @notice Returns the max amount of total assets possible */
	function maxTotalAssets() external view returns (uint256) {
		return vaultStorage().maxTotalAssets;
	}

	/**
	 * @notice Checks if an amount of assets are above the max amount possible to deposit
	 * @param assets The amount of assets to check
	 */
	function checkMaxDeposit(uint256 assets) internal view {
		if (assets > maxDepositLimit()) {
			revert DynaVaultErrors.MaxDeposit();
		}
	}

	/**
	 * @notice Checks if an amount of assets is below the min deposit limit
	 * @param assets The amount of assets to check
	 */
	function checkMinDeposit(uint256 assets) internal view {
		if (assets <= vaultStorage().minDepositAssets) {
			revert DynaVaultErrors.MinDeposit();
		}
	}

	/** @notice Returns the max amount of shares that can be minted */
	function maxMint() internal view returns (uint256) {
		uint256 maxDepositAssets = maxDepositLimit();
		return (maxDepositAssets == type(uint256).max) ? type(uint256).max : convertToShares(maxDepositAssets);
	}

	/**
	 * @notice Checks if an amount of shares exceeds the max amount possible
	 * @param shares amount of shares to check
	 */
	function checkMaxMint(uint256 shares) external view {
		if (shares > maxMint()) {
			revert DynaVaultErrors.MaxMint();
		}
	}

	/**
	 * Maximum amount of the underlying asset that can be withdrawn from the owner balance in the Vault,
	 * through a withdraw call.
	 * @notice This does not include fees to allow exiting the vault withdrawing the asset value of the entire balance.
	 * @param owner The address of the owner of the shares to withdraw.
	 * @return The maximum amount of assets that can be withdrawn.
	 */
	function maxWithdraw(address owner) internal view returns (uint256) {
		return _convertToAssetsGivenTotalSupply(sharesOf(owner), totalSupply(), Math.Rounding.Down);
	}

	/**
	 * @dev Check if withdrawal of assets is within limits.
	 * @param assets The amount of assets to withdraw.
	 * @param owner The address of the owner.
	 */
	function checkWithdraw(uint256 assets, address owner) internal view returns (uint256 maxAssets) {
		maxAssets = maxWithdraw(owner);
		if (assets > maxAssets) {
			revert DynaVaultErrors.MaxWithdraw();
		}
		uint256 remainingAssets = maxAssets - assets;
		if (remainingAssets != 0 && remainingAssets < vaultStorage().minDepositAssets) {
			revert DynaVaultErrors.MinWithdraw();
		}
	}

	/**
	 * @notice Wraps erc20 balanceOf
	 * @param user The address of the user.
	 * @return Shares balance of user.
	 */
	function sharesOf(address user) internal view returns (uint256) {
		return IERC20(address(this)).balanceOf(user);
	}

	/** @notice Allows vault to report reserves during withdraw and redeem */
	function reportAllReserves() internal returns (uint256 reportedFreeFunds) {
		reportedFreeFunds = _manager().reportAllReservesFromVault();
	}

	/**
	 * Maximum amount of shares that can be withdrawn from the owner balance in the Vault,
	 * through a redeem call.
	 * @notice This does not include fees to allow exiting the vault redeeming entire balance.
	 * @param owner The address of the owner of the shares to redeem.
	 * @return The maximum amount of assets that can be withdrawn.
	 */
	function maxRedeem(address owner) internal view returns (uint256) {
		return sharesOf(owner);
	}

	/**
	 * @dev Check if redeem of shares is within limits.
	 * @param shares The amount of assets to withdraw.
	 * @param owner The address of the owner.
	 * @param reportedFreeFunds The reported free funds in the vault
	 */
	function checkRedeem(uint256 shares, address owner, uint256 reportedFreeFunds) external view {
		uint256 maxShares = maxRedeem(owner);
		if (shares > maxShares) {
			revert DynaVaultErrors.MaxRedeem();
		}
		uint256 remainingShares = maxShares - shares;
		if (
			remainingShares != 0 &&
			_convertToAssetsGivenTotalSupplyAndFreeFunds(remainingShares, totalSupply(), reportedFreeFunds, Math.Rounding.Down) <
			vaultStorage().minDepositAssets
		) {
			revert DynaVaultErrors.MinRedeem();
		}
	}

	/**
	 * @notice Return preview of deposit
	 * @param assets The amount of assets to deposit
	 * @param reportedFreeFunds The reported free funds in vault
	 */
	function previewDeposit(uint256 assets, uint256 reportedFreeFunds) external view returns (uint256) {
		uint256 depositFee = _manager().getFees().depositFee;
		return _convertToSharesGivenTotalSupplyAndFreeFunds(assets - _feeOnTotal(assets, depositFee), totalSupply(), reportedFreeFunds, Math.Rounding.Down);
	}

	/**
	 * @notice previews value of amount of shares to mint
	 * @param shares amount of shares minted
	 * @param reportedFreeFunds The reported free funds in vault
	 * @return assets value of shares including fees
	 */
	function previewMint(uint256 shares, uint256 reportedFreeFunds) internal view returns (uint256) {
		uint256 depositFee = _manager().getFees().depositFee;
		uint256 assets = _convertToAssetsGivenTotalSupplyAndFreeFunds(shares, totalSupply(), reportedFreeFunds, Math.Rounding.Up);
		return assets + _feeOnRaw(assets, depositFee);
	}

	/**
	 * @notice Return preview of withdraw
	 * @param assets The amount of assets to withdraw
	 */
	function previewWithdraw(uint256 assets) internal view returns (uint256) {
		return _convertToSharesGivenTotalSupply(assets + _calculateRedemptionFee(assets), totalSupply(), Math.Rounding.Up);
	}

	/**
	 * @notice Return preview of redeem
	 * @param shares The amount of shares to redeem
	 */
	function previewRedeem(uint256 shares) public view returns (uint256) {
		uint256 redemptionFee = _manager().getFees().redemptionFee;
		uint256 assets = _convertToAssetsGivenTotalSupply(shares, totalSupply(), Math.Rounding.Down);
		return assets - _feeOnTotal(assets, redemptionFee);
	}

	/**
	 * @notice Returns shares ratio based on unlocked funds and of total supply
	 * @param shares The amount of shares to convert
	 * @return ratio Ratio in PRECISION decimals
	 */
	function _convertToRatio(uint256 shares) private view returns (uint256 ratio) {
		ratio = FixedPointMathLib.fullMulDiv(shares, _manager().unlockedFundsRatio(), totalSupply());
	}

	/**
	 * @notice Calculates amounts for redeem proportional
	 * @param shares The amount of shares to redeem
	 * @return toRedeem An array of proportional amounts to redeem
	 */
	function calcRedeemProportional(uint256 shares) external returns (uint256[] memory) {
		IVaultManagerAPI manager = _manager();
		uint256 ratio = _convertToRatio(shares);
		uint256 nrOfTokens = manager.nrOfTokens();
		uint256[] memory toRedeem = new uint256[](nrOfTokens);
		for (uint256 i = 0; i < nrOfTokens; ++i) {
			address tokenAddress = manager.tokens(i);
			TokenStats memory stats = manager.tokenStats(tokenAddress);
			uint256 tokenTotal = stats.tokenIdle + stats.tokenDebt;
			toRedeem[i] = FixedPointMathLib.fullMulDiv(tokenTotal, ratio, PRECISION);
			if (toRedeem[i] > stats.tokenIdle) {
				// fetch from strategies
				(uint256 totalLoss, uint256 totalWithdrawn) = _withdrawTokenDebtFromStrategies(tokenAddress, toRedeem[i] - stats.tokenIdle);
				// adjust toRedeem based on loss incurred during withdrawal
				if (totalLoss > 0) {
					toRedeem[i] -= Math.min(toRedeem[i], totalLoss);
				}
				// update amountIdle after withdrawal
				manager.depositIdle(tokenAddress, totalWithdrawn);
			}
		}
		return toRedeem;
	}

	/**
	 * @notice Transfers proportional amounts of reserve tokens
	 * @param receiver The address of receiver
	 * @param toRedeem Array of token amounts to redeem
	 */
	function transferProportional(address receiver, uint256[] memory toRedeem) external {
		IVaultManagerAPI manager = _manager();
		uint256 nrOfTokens = manager.nrOfTokens();
		if (toRedeem.length != nrOfTokens) {
			revert DynaVaultErrors.ArrayMismatch();
		}
		uint256 redemptionFee = manager.getFees().redemptionFee;
		address feeRecipient = manager.getFees().redemptionFeeWallet;
		for (uint256 i = 0; i < nrOfTokens; ++i) {
			address token = manager.tokens(i);
			uint256 fee = 0;
			manager.withdrawIdle(token, toRedeem[i]);
			if (toRedeem[i] != 0 && redemptionFee != 0) fee = _feeOnTotal(toRedeem[i], redemptionFee);
			IERC20(token).safeTransfer(receiver, toRedeem[i] - fee);
			if (fee != 0 && feeRecipient != address(this)) {
				IERC20(token).safeTransfer(feeRecipient, fee);
			}
		}
	}

	/**
	 * @notice Returns value of token in quote asset
	 * @param base The address of base token
	 * @param amount The amount of token
	 * @param quote The address of quote token
	 * @return value The value of amount in quote token
	 */
	function tokenValueInQuoteAsset(address base, uint256 amount, address quote) internal view returns (uint256 value) {
		IReferenceAssetOracle _referenceAssetOracle = IReferenceAssetOracle(VaultConfigLib.referenceAssetOracle());
		(uint256 price, ) = _referenceAssetOracle.getPrice(base, quote);
		return FixedPointMathLib.fullMulDiv(price, amount, (10 ** IERC20Metadata(base).decimals()));
	}

	/**
	 * @notice feeShares is approximated instead of being computed with the formula:
	 * amount * supply / (assets - amount)
	 * Minting shares increases the supply, so if you don't correct for this dilution during the calculation,
	 * your shares would be worth a lot less than the intended fees.
	 * @param feeAmount The amount of fees
	 * @param feeToken The address of the fee token
	 * @param deltaTotalAssets Updates total assets in fee shares calculation
	 * @return feeShares The amount of shares to mint for fees
	 */
	function calcSharesForFeeAmount(uint256 feeAmount, address feeToken, uint256 deltaTotalAssets) internal view returns (uint256 feeShares) {
		feeShares = calcSharesForFeeAmountUsingGivenTotalSupplyAndTotalAssets(feeAmount, feeToken, deltaTotalAssets, totalSupply(), totalAssets());
	}

	/**
	 * @notice Calculates shares for fees with given values for total supply and total assets
	 * @param feeAmount The amount for fees
	 * @param feeToken The address of fee token
	 * @param deltaTotalAssets Updates total assets in fee shares calculation
	 * @param givenTotalSupply The amount of total supply to use in calculation
	 * @param givenTotalAssets The amount of total assets to use in calculation
	 * @return feeShares The amount of shares to mint for fees
	 */
	function calcSharesForFeeAmountUsingGivenTotalSupplyAndTotalAssets(
		uint256 feeAmount,
		address feeToken,
		uint256 deltaTotalAssets,
		uint256 givenTotalSupply,
		uint256 givenTotalAssets
	) internal view returns (uint256 feeShares) {
		address depositToken = _asset();
		uint256 feeAmountInDepositToken = (feeToken == depositToken) ? feeAmount : tokenValueInQuoteAsset(feeToken, feeAmount, depositToken);
		uint256 _freeFunds = givenTotalAssets;
		uint256 unlockedRatio = _manager().unlockedFundsRatio();
		if (deltaTotalAssets != 0) {
			// calculate free amount with updated total assets when reporting from strategy
			uint256 deltaTotalAssetsInDeposit = (feeToken == depositToken)
				? deltaTotalAssets
				: tokenValueInQuoteAsset(feeToken, deltaTotalAssets, depositToken);
			_freeFunds = FixedPointMathLib.fullMulDiv(_freeFunds + deltaTotalAssetsInDeposit, unlockedRatio, PRECISION);
		} else {
			_freeFunds = FixedPointMathLib.fullMulDiv(_freeFunds, unlockedRatio, PRECISION);
		}
		if (_freeFunds != 0) {
			uint256 lastFeeSharesApproximation;
			for (uint8 i = 0; i < FEE_CALC_ITERATIONS; ++i) {
				// Calculate the Error Term and refine the approximation
				feeShares += ((feeAmountInDepositToken * (givenTotalSupply + feeShares)) / _freeFunds) - feeShares;
				if (feeShares == lastFeeSharesApproximation) break;
				lastFeeSharesApproximation = feeShares;
			}
		}
	}

	/**
	 * @notice Calculates shares for fees with given values for total supply and free funds
	 * @param feeAmount The amount for fees
	 * @param feeToken The address of fee token
	 * @param givenTotalSupply The amount of total supply to use in calculation
	 * @param givenFreeFunds The amount of free funds to use in calculation
	 * @return feeShares The amount of shares to mint for fees
	 */
	function calcSharesForFeeAmountUsingGivenTotalSupplyAndFreeFunds(
		uint256 feeAmount,
		address feeToken,
		uint256 givenTotalSupply,
		uint256 givenFreeFunds
	) internal view returns (uint256 feeShares) {
		address depositToken = _asset();
		uint256 feeAmountInDepositToken = (feeToken == depositToken) ? feeAmount : tokenValueInQuoteAsset(feeToken, feeAmount, depositToken);
		if (givenFreeFunds != 0) {
			uint256 lastFeeSharesApproximation;
			for (uint8 i = 0; i < FEE_CALC_ITERATIONS; ++i) {
				// Calculate the Error Term and refine the approximation
				feeShares += ((feeAmountInDepositToken * (givenTotalSupply + feeShares)) / givenFreeFunds) - feeShares;
				if (feeShares == lastFeeSharesApproximation) break;
				lastFeeSharesApproximation = feeShares;
			}
		}
	}

	/**
	 * @dev Deposit/mint common workflow.
	 * @param caller The address of caller
	 * @param assetsIncludingFees The amount of assets including fees
	 * @return fee The fee amount
	 */
	function beforeMint(address caller, uint256 assetsIncludingFees) external returns (uint256 fee) {
		// If token is ERC777, `transferFrom` can trigger a reentrancy BEFORE the transfer happens through the
		// `tokensToSend` hook. On the other hand, the `tokenReceived` hook, that is triggered after the transfer,
		// calls the vault, which is assumed not malicious.
		//
		// Conclusion: we need to do the transfer before we mint so that any reentrancy would happen before the
		// assets are transferred and before the shares are minted, which is a valid state.
		IVaultManagerAPI manager = _manager();
		address token = _asset();
		if (IERC20(token).balanceOf(caller) < assetsIncludingFees) {
			revert DynaVaultErrors.ERC20InsufficientBalance();
		}
		if (IERC20(token).allowance(caller, address(this)) < assetsIncludingFees) {
			revert DynaVaultErrors.ERC20InsufficientAllowance();
		}
		uint256 depositFee = manager.getFees().depositFee;
		fee = _feeOnTotal(assetsIncludingFees, depositFee);
		IERC20(token).safeTransferFrom(caller, address(this), assetsIncludingFees);
		manager.depositDepositToken(assetsIncludingFees, fee);
	}

	/**
	 * @notice Transfers fee to fee recipient
	 * @param caller The address of the caller
	 * @param receiver The address of the receiver
	 * @param assetsIncludingFees The amount of assets including amount for fees
	 * @param _sharesWithoutFees The amount of shares not including fees
	 * @param fee The fee amount
	 */
	function afterMint(address caller, address receiver, uint256 assetsIncludingFees, uint256 _sharesWithoutFees, uint256 fee) external {
		emit Deposit(caller, receiver, assetsIncludingFees, _sharesWithoutFees);
		address feeRecipient = _manager().getFees().depositFeeWallet;
		if (fee > 0 && feeRecipient != address(this)) {
			SafeERC20.safeTransfer(IERC20(_asset()), feeRecipient, fee);
		}
	}

	/**
	 * @notice Withdraw debt from strategy
	 * @param strategy The address of strategy
	 * @param tokenAddress The address of token
	 * @param amountNeeded The amount wanted to withdraw
	 */
	function _withdrawStrategyDebt(
		address strategy,
		address tokenAddress,
		uint256 amountNeeded
	) private returns (uint256 strategyDebt, uint256 loss, uint256 withdrawn) {
		// NOTE: Don't withdraw more than the debt so that Strategy can still
		//       continue to work based on the profits it has
		// NOTE: This means that user will lose out on any profits that each
		//       Strategy in the queue would return on next harvest, benefiting others
		strategyDebt = _manager().strategyDebt(strategy);
		if (amountNeeded > strategyDebt) amountNeeded = strategyDebt;
		// Withdraw amount
		uint256 preBalance = IERC20(tokenAddress).balanceOf(address(this));
		loss = IDynaStrategyAPI(strategy).withdraw(amountNeeded);
		withdrawn = IERC20(tokenAddress).balanceOf(address(this)) - preBalance;
	}

	/**
	 * @notice Withdraw token debt from strategies
	 * @param tokenAddress The address of token to withdraw
	 * @param valueToWithdraw The amount of tokens to withdraw
	 */
	function withdrawTokenDebtFromStrategies(address tokenAddress, uint256 valueToWithdraw) internal returns (uint256 totalLoss, uint256 totalWithdrawn) {
		VaultConfigLib.onlyManager();
		return _withdrawTokenDebtFromStrategies(tokenAddress, valueToWithdraw);
	}

	/**
	 * @dev Withdraw/redeem common workflow.
	 * @param assetsNotIncludingFees The assets that receiver will get
	 * @param sharesIncludingFees The shares that are burned
	 * @return assetsToWithdraw The amount of assets to withdraw
	 */
	function beforeBurn(uint256 assetsNotIncludingFees, uint256 sharesIncludingFees) external returns (uint256 assetsToWithdraw) {
		IVaultManagerAPI manager = _manager();
		uint256 redemptionFee = manager.getFees().redemptionFee;
		uint256 fee = _feeOnRaw(assetsNotIncludingFees, redemptionFee);
		(uint256 tokenIdle, uint256 tokenDebt) = manager.tokenIdleDebt(_asset());
		// we must have enough tokens to send to both the withdrawer and the fee recipient
		if (tokenIdle >= assetsNotIncludingFees + fee) {
			assetsToWithdraw = assetsNotIncludingFees + fee;
		} else {
			// if deposit token vault idle balance is not sufficient,
			// start swapping reserve assets based on shares/totalSupply ratio
			uint256 nrOfTokens = manager.nrOfTokens();
			uint256 ratio = FixedPointMathLib.fullMulDiv(sharesIncludingFees, PRECISION, totalSupply());
			uint256 totalLoss;
			uint256 depositTokensAllocatedForWithdraw;
			address asset = _asset();
			for (uint256 t = 0; t < nrOfTokens; ++t) {
				address tokenAddress = manager.tokens(t);
				(tokenIdle, tokenDebt) = manager.tokenIdleDebt(tokenAddress);
				uint256 toRedeem = FixedPointMathLib.fullMulDiv((tokenIdle + tokenDebt), ratio, PRECISION);
				if (toRedeem == 0) continue;
				if (tokenIdle < toRedeem) {
					// fetch from strategies
					(uint256 tokenLoss, uint256 tokenWithdrawn) = _withdrawTokenDebtFromStrategies(tokenAddress, toRedeem - tokenIdle);
					// adjust toRedeem based on loss incurred during withdrawal
					if (tokenLoss != 0) {
						toRedeem = (tokenLoss < toRedeem) ? toRedeem - tokenLoss : 0;
						totalLoss += (t > 0 && tokenLoss > 0) ? tokenValueInQuoteAsset(tokenAddress, tokenLoss, asset) : tokenLoss;
					}
					// update tokenIdle after withdrawal
					manager.depositIdle(tokenAddress, tokenWithdrawn);
				}
				// no need to swap for deposit token
				if (t == 0) {
					depositTokensAllocatedForWithdraw = toRedeem;
					continue;
				}
				// swap reserve to deposit
				uint256 amountOut;
				{
					(, address selectedRouter, bytes32[] memory swapData) = VaultRouterLib.previewSwap(tokenAddress, toRedeem, asset);
					uint256 allowed = IERC20(tokenAddress).allowance(address(this), selectedRouter);
					if (allowed < toRedeem) IERC20(tokenAddress).safeIncreaseAllowance(selectedRouter, toRedeem);
					uint256 tokenOutInitialBalance = IERC20(asset).balanceOf(address(this));
					IDynaRouterAPI(selectedRouter).swap(tokenAddress, toRedeem, asset, 0, address(this), swapData);
					amountOut = IERC20(asset).balanceOf(address(this)) - tokenOutInitialBalance;
				}
				depositTokensAllocatedForWithdraw += amountOut;
				manager.updateDebtAfterSwap(tokenAddress, toRedeem, asset, amountOut, false);
			}
			manager.setTotalIdle(asset, IERC20(asset).balanceOf(address(this)));
			// NOTE: This loss protection is put in place to revert if losses from
			//       withdrawing from strategies are more than what is considered acceptable.
			{
				// fix stack too deep
				uint256 depositTokensToWithdraw = assetsNotIncludingFees + fee;
				uint256 maxLoss = VaultConfigLib.maxLoss(); // max loss BPS for loss protection
				if (totalLoss > FixedPointMathLib.fullMulDiv(maxLoss, depositTokensToWithdraw, MAX_BPS)) {
					revert DynaVaultErrors.StrategyLossProtection(depositTokensToWithdraw, totalLoss, maxLoss);
				}
				assetsToWithdraw = Math.min(depositTokensAllocatedForWithdraw, depositTokensToWithdraw);
			}
		}
		// withdraw from tokenIdle and update locked profit ratio based on assetsToWithdraw including redemption fees
		_manager().withdrawDepositToken(assetsToWithdraw);
		address feeRecipient = manager.getFees().redemptionFeeWallet;
		// we send to the fee recipient when needed
		if (fee > 0 && feeRecipient != address(this)) {
			SafeERC20.safeTransfer(IERC20(_asset()), feeRecipient, fee);
		}
		// always subtract fee from assetsToWithdraw amount to adjust the amount returned
		assetsToWithdraw = assetsToWithdraw > fee ? assetsToWithdraw - fee : 0;
	}

	/**
	 * @notice Called during withdraw after burning of the users shares, is responsible to send assets to the receiver
	 * @param caller the address of the caller
	 * @param receiver The address of the receiver
	 * @param owner The address of the owner
	 * @param assetsNotIncludingFees The assets that receiver will get
	 * @param sharesIncludingFeesBurned The shares that are burned
	 */
	function afterBurn(address caller, address receiver, address owner, uint256 assetsNotIncludingFees, uint256 sharesIncludingFeesBurned) external {
		IERC20(_asset()).safeTransfer(receiver, assetsNotIncludingFees);
		emit Withdraw(caller, receiver, owner, assetsNotIncludingFees, sharesIncludingFeesBurned);
	}

	/**
	 * @notice Internal function returns a calculated redemption fee amount
	 * @param assets The amount of assets to calculate amount on
	 * @return fees The amount of fees on assets
	 */
	function _calculateRedemptionFee(uint256 assets) private view returns (uint256 fees) {
		fees = _feeOnRaw(assets, _manager().getFees().redemptionFee);
	}

	/**
	 * @notice Internal function returns max redemption without fee amount
	 * @param shares The amount of shares to calculate amount on
	 * @return assetsNotIncludingFees The assets without fees
	 */
	function _calculateMaxAssetsNotIncludingFees(uint256 shares) private view returns (uint256 assetsNotIncludingFees) {
		uint256 maxAssetsIncludingFees = convertToAssets(shares, Math.Rounding.Down);
		return maxAssetsIncludingFees - _calculateRedemptionFee(maxAssetsIncludingFees);
	}

	/**
	 * @notice Reports all reserves and calculates shares to burn when withdrawing assets
	 * @param assetsNotIncludingFees The amount of assets not including  fees
	 * @param owner The address of the owner
	 * @return sharesToBurn The amount of shares to burn
	 * @return assetsExcludingFees The amount of assets excluding fees
	 */
	function reportAndCalculateWithdraw(uint256 assetsNotIncludingFees, address owner) internal returns (uint256 sharesToBurn, uint256 assetsExcludingFees) {
		uint256 freeFunds = reportAllReserves();
		uint256 sharesIncludingFees;
		if (assetsNotIncludingFees == type(uint256).max) {
			sharesIncludingFees = sharesOf(owner);
			assetsNotIncludingFees = _calculateMaxAssetsNotIncludingFees(sharesIncludingFees);
		} else {
			uint256 totalShares = totalSupply();
			// check withdraw
			uint256 maxAssets = _convertToAssetsGivenTotalSupplyAndFreeFunds(sharesOf(owner), totalShares, freeFunds, Math.Rounding.Down);
			if (assetsNotIncludingFees > maxAssets) revert DynaVaultErrors.MaxWithdraw();
			uint256 remainingAssets = maxAssets - assetsNotIncludingFees;
			if (remainingAssets != 0 && remainingAssets < vaultStorage().minDepositAssets) {
				revert DynaVaultErrors.MinWithdraw();
			}
			// preview withdraw
			sharesIncludingFees = _convertToSharesGivenTotalSupplyAndFreeFunds(
				assetsNotIncludingFees + _calculateRedemptionFee(assetsNotIncludingFees),
				totalShares,
				freeFunds,
				Math.Rounding.Up
			);
		}
		if (sharesIncludingFees == 0) {
			revert DynaVaultErrors.ZeroShares();
		}
		return (sharesIncludingFees, assetsNotIncludingFees);
	}

	/**
	 * @notice Reports all reserves and calculates assets to withdraw
	 * @param sharesIncludingFees The amount of shares including  fees
	 * @param owner The address of the owner
	 * @return assetsExcludingFees The amount of assets excluding fees
	 */
	function reportAndCalculateRedeem(uint256 sharesIncludingFees, address owner) internal returns (uint256 assetsExcludingFees) {
		uint256 freeFunds = reportAllReserves();
		uint256 totalShares = totalSupply();

		// checkRedeem
		uint256 maxShares = maxRedeem(owner);
		if (sharesIncludingFees > maxShares) revert DynaVaultErrors.MaxRedeem();
		uint256 remainingShares = maxShares - sharesIncludingFees;
		if (
			remainingShares != 0 &&
			_convertToAssetsGivenTotalSupplyAndFreeFunds(remainingShares, totalShares, freeFunds, Math.Rounding.Down) < vaultStorage().minDepositAssets
		) {
			revert DynaVaultErrors.MinRedeem();
		}

		// previewRedeem
		uint256 redemptionFee = _manager().getFees().redemptionFee;
		uint256 assets = _convertToAssetsGivenTotalSupplyAndFreeFunds(sharesIncludingFees, totalShares, freeFunds, Math.Rounding.Down);
		assetsExcludingFees = assets - _feeOnTotal(assets, redemptionFee);
	}

	/**
	 * @notice Returns fee amount on the raw assets amount
	 * @param assets The amount of assets
	 * @param feeBasePoint The fee base points
	 */
	function _feeOnRaw(uint256 assets, uint256 feeBasePoint) private pure returns (uint256) {
		return feeBasePoint > 0 ? FixedPointMathLib.fullMulDivUp(assets, feeBasePoint, MAX_BPS) : 0;
	}

	/**
	 * @notice Returns fee amount on total
	 * @param assets The amount of assets
	 * @param feeBasePoint The fee base points
	 */
	function _feeOnTotal(uint256 assets, uint256 feeBasePoint) private pure returns (uint256) {
		return feeBasePoint > 0 ? FixedPointMathLib.fullMulDivUp(assets, feeBasePoint, feeBasePoint + MAX_BPS) : 0;
	}

	/**
	 * @notice Withdraw token debt from strategies
	 * @param tokenAddress The address of token to withdraw
	 * @param valueToWithdraw The amount of tokens to withdraw
	 */
	function _withdrawTokenDebtFromStrategies(address tokenAddress, uint256 valueToWithdraw) private returns (uint256 totalLoss, uint256 totalWithdrawn) {
		IVaultManagerAPI manager = _manager();
		// We need to go get some from our strategies in the withdrawal queue
		// NOTE: This performs forced withdrawals from each Strategy. During
		//       forced withdrawal, a Strategy may realize a loss. That loss
		//       is reported back to the Vault, and the will affect the amount
		//       of tokens that the withdrawer receives for their shares. They
		//       can optionally specify the maximum acceptable loss (in BPS)
		//       to prevent excessive losses on their withdrawals (which may
		//       happen in certain edge cases where Strategies realize a loss)
		uint256 valueAllocatedForWithdraw;
		address[] memory tokenStrategies = manager.getTokenStrategies(tokenAddress);
		for (uint256 s = 0; s < tokenStrategies.length; s++) {
			address strategy = tokenStrategies[s];
			if (strategy == ZERO_ADDRESS) break; // We've exhausted the queue
			if (valueToWithdraw <= valueAllocatedForWithdraw) break; // We're done withdrawing
			uint256 amountNeeded = valueToWithdraw - valueAllocatedForWithdraw;
			(uint256 strategyDebt, uint256 loss, uint256 withdrawn) = _withdrawStrategyDebt(strategy, tokenAddress, amountNeeded);
			totalWithdrawn += withdrawn;
			valueAllocatedForWithdraw += withdrawn;
			// NOTE: Withdrawer incurs any losses from liquidation
			if (loss != 0) {
				valueToWithdraw -= loss;
				totalLoss += loss;
				manager.reportLoss(strategy, loss);
			}
			// Reduce the Strategy's debt by the amount withdrawn ("realized returns")
			// NOTE: This doesn't add to returns as it's not earned by "normal means"
			manager.decreaseStrategyDebt(strategy, withdrawn);
			emit WithdrawFromStrategy(strategy, strategyDebt, loss);
		}
	}
}
