// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./interfaces/IDynaVaultAPI.sol";
import "./interfaces/IDynaRouterAPI.sol";
import "./interfaces/IVaultSimulatorAPI.sol";
import "./VaultConfigLib.sol";
import "./DynaVaultLib.sol";
import "./VaultRouterLib.sol";
import "./DynaVaultErrors.sol";
import "./utils/ERC20.sol";
import "./utils/ReentrancyGuard.sol";
import "./utils/Checks.sol";
import "./utils/Clonable.sol";

/**
 * @dev "DynaVault" vault using Implementation of the ERC4626 "Tokenized Vault Standard" as defined in
 * https://eips.ethereum.org/EIPS/eip-4626[EIP-4626].
 *
 * This extension allows the minting and burning of "shares" (represented using the ERC20 inheritance) in exchange for
 * underlying "assets" through standardized {deposit}, {mint}, {redeem} and {burn} workflows. This contract extends
 * the ERC20 standard. Any additional extensions included along it would affect the "shares" token represented by this
 * contract and not the "assets" token which is an independent contract.
 *
 * @notice We do not support fee-on-transfer tokens and they should not be used as deposit or reserve tokens!
 *
 * CAUTION: Deposits and withdrawals may incur unexpected slippage. Users should verify that the amount received of
 * shares or assets is as expected. For this reason we implement EIP-5143 to have check slippage.
 */
contract DynaVault is ERC20, IDynaVaultAPI, Clonable, ReentrancyGuard {
	using Checks for address;

	address public simulator;

	/**
	 * @notice Initializes the vault parameters
	 * @param nameOverride The vault name
	 * @param symbolOverride The vault symbol
	 * @param managerAddress The address of the vault manager
	 * @param referenceAssetOracleAddress The address of the reference asset oracle
	 * @param dynaRouterRegistryAddress The address of the DynaRouter registry
	 * @param ownerAddress The address of the owner
	 */
	function initialize(
		string memory nameOverride,
		string memory symbolOverride,
		address managerAddress,
		address referenceAssetOracleAddress,
		address dynaRouterRegistryAddress,
		address ownerAddress,
		address vaultSimulatorAddress
	) public virtual {
		ownerAddress.requireNonZeroAddress();
		// grantRole is reverting when executed by user without admin role
		_grantRole(DEFAULT_ADMIN_ROLE, ownerAddress);
		initializeERC20(nameOverride, symbolOverride);
		VaultConfigLib.initialize(managerAddress, dynaRouterRegistryAddress, referenceAssetOracleAddress);
		DynaVaultLib.initialize();
		simulator = vaultSimulatorAddress;
		IVaultSimulatorAPI(vaultSimulatorAddress).initialize(address(this), managerAddress, uint8(VaultConfigLib.depositDecimals()));
	}

	/**
	 * @notice Takes a snapshot of the vault that can be used for simulating vault actions such as reporting
	 * @return snapshot A vault snapshot that can be used for simulation
	 */
	function takeSnapshot() public view returns (IVaultSimulatorAPI.VaultSnapshot memory) {
		return IVaultSimulatorAPI(simulator).takeSnapshot();
	}

	/** @dev See {IERC4626-asset} */
	function asset() external view override returns (address) {
		return VaultConfigLib.asset();
	}

	/** @dev See {IERC4626-totalAssets} */
	function totalAssets() external view virtual override returns (uint256 total) {
		total = DynaVaultLib.totalAssets();
	}

	/**
	 * @notice Returns the value of one share in deposit token
	 * @return assetsPerShare The value of one share in deposit token
	 */
	function assetsPerShare() public view virtual returns (uint256) {
		return IVaultSimulatorAPI(simulator).assetsPerShare();
	}

	/** @dev See {IERC4626-convertToShares} */
	function convertToShares(uint256 assets) external view override returns (uint256 shares) {
		return IVaultSimulatorAPI(simulator)._convertToShares(assets);
	}

	/** @dev See {IERC4626-convertToAssets} */
	function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
		return IVaultSimulatorAPI(simulator)._convertToAssets(shares);
	}

	/** @dev See {IERC4626-maxDeposit} */
	function maxDeposit(address) external view virtual override returns (uint256) {
		return DynaVaultLib.maxDepositLimit();
	}

	/** @dev See {IERC4626-maxMint} */
	function maxMint(address) external view virtual override returns (uint256) {
		return DynaVaultLib.maxMint();
	}

	/** @dev See {IERC4626-maxWithdraw} */
	function maxWithdraw(address owner) external view virtual override returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedMaxWithdraw(owner, takeSnapshot());
	}

	/**
	 * @notice Simulates max withdraw
	 * @param owner The address of owner
	 * @param snapshot The vault snapshot used in the simulation
	 * @return amount Max amount of tokens that can be withdrawn
	 */
	function simulatedMaxWithdraw(address owner, IVaultSimulatorAPI.VaultSnapshot memory snapshot) external view returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedMaxWithdraw(owner, snapshot);
	}

	/**
	 * @notice Wraps balanceOf
	 * @param user The address of user
	 * @return shares The amount of shares owned by user
	 */
	function sharesOf(address user) external view virtual returns (uint256) {
		return DynaVaultLib.sharesOf(user);
	}

	/** @dev See {IERC4626-maxRedeem} */
	function maxRedeem(address owner) external view virtual override returns (uint256) {
		return DynaVaultLib.maxRedeem(owner);
	}

	/** @dev See {IERC4626-previewDeposit} */
	function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedDeposit(assets, takeSnapshot());
	}

	/**
	 * @dev Simulates the calculation of how many shares should be minted for a deposit
	 * @param assets The amount of fees
	 * @param snapshot The current vault snapshot
	 * @return shares The simulated amount of shares
	 */
	function simulatedDeposit(uint256 assets, IVaultSimulatorAPI.VaultSnapshot memory snapshot) public view returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedDeposit(assets, snapshot);
	}

	/** @dev See {IERC4626-previewMint} */
	function previewMint(uint256 shares) public view virtual override returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedMint(shares, takeSnapshot());
	}

	/** @dev See {IERC4626-previewWithdraw} */
	function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedWithdraw(assets, takeSnapshot());
	}

	/** @dev See {IERC4626-previewRedeem} */
	function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
		return IVaultSimulatorAPI(simulator).simulatedRedeem(shares, takeSnapshot());
	}

	/** @dev See {IERC4626-deposit} */
	function deposit(uint256 assetsIncludingFees, address receiver) public virtual override returns (uint256 sharesNotIncludingFees) {
		receiver.requireNonZeroAddress();
		before_nonReentrant();
		uint256 reportedFreeFunds = DynaVaultLib.reportAllReserves();
		DynaVaultLib.checkMaxDeposit(assetsIncludingFees);
		DynaVaultLib.checkMinDeposit(assetsIncludingFees);
		sharesNotIncludingFees = DynaVaultLib.previewDeposit(assetsIncludingFees, reportedFreeFunds);
		_deposit(msg.sender, receiver, assetsIncludingFees, sharesNotIncludingFees);
		after_nonReentrant();
	}

	/** @dev See {IERC4626-mint} */
	function mint(uint256 sharesNotIncludingFees, address receiver) public virtual override returns (uint256 assetsIncludingFees) {
		receiver.requireNonZeroAddress();
		before_nonReentrant();
		uint256 reportedFreeFunds = DynaVaultLib.reportAllReserves();
		DynaVaultLib.checkMaxMint(sharesNotIncludingFees);
		assetsIncludingFees = DynaVaultLib.previewMint(sharesNotIncludingFees, reportedFreeFunds);
		DynaVaultLib.checkMinDeposit(assetsIncludingFees);
		_deposit(msg.sender, receiver, assetsIncludingFees, sharesNotIncludingFees);
		after_nonReentrant();
	}

	/** @dev See {IERC4626-withdraw} */
	function withdraw(uint256 assetsNotIncludingFees, address receiver, address owner) public virtual override returns (uint256 sharesIncludingFees) {
		owner.requireNonZeroAddress();
		receiver.requireNonZeroAddress();
		before_nonReentrant();
		(sharesIncludingFees, assetsNotIncludingFees) = DynaVaultLib.reportAndCalculateWithdraw(assetsNotIncludingFees, owner);
		_withdraw(msg.sender, receiver, owner, assetsNotIncludingFees, sharesIncludingFees);
		after_nonReentrant();
	}

	/** @dev See {IERC4626-redeem} */
	function redeem(uint256 sharesIncludingFees, address receiver, address owner) public virtual override returns (uint256 assetsNotIncludingFees) {
		owner.requireNonZeroAddress();
		receiver.requireNonZeroAddress();
		before_nonReentrant();
		assetsNotIncludingFees = DynaVaultLib.reportAndCalculateRedeem(sharesIncludingFees, owner);
		_withdraw(msg.sender, receiver, owner, assetsNotIncludingFees, sharesIncludingFees);
		after_nonReentrant();
	}

	/** @dev See {IERC5143-deposit} */
	function depositCheckSlippage(uint256 assets, address receiver, uint256 minShares) public virtual override returns (uint256 shares) {
		shares = deposit(assets, receiver);
		DynaVaultErrors.checkSlippageAbove(shares, minShares);
	}

	/** @dev See {IERC5143-mint} */
	function mintCheckSlippage(uint256 shares, address receiver, uint256 maxAssets) public virtual override returns (uint256 assets) {
		assets = mint(shares, receiver);
		DynaVaultErrors.checkSlippageBelow(assets, maxAssets);
	}

	/** @dev See {IERC5143-withdraw} */
	function withdrawCheckSlippage(uint256 assets, address receiver, address owner, uint256 maxShares) public virtual override returns (uint256 shares) {
		shares = withdraw(assets, receiver, owner);
		DynaVaultErrors.checkSlippageBelow(shares, maxShares);
	}

	/** @dev See {IERC5143-redeem} */
	function redeemCheckSlippage(uint256 shares, address receiver, address owner, uint256 minAssets) public virtual override returns (uint256 assets) {
		assets = redeem(shares, receiver, owner);
		DynaVaultErrors.checkSlippageAbove(assets, minAssets);
	}

	/**
	 * @notice Redeems an amount of shares paid out in proportional amounts of reserve tokens
	 * @param sharesIncludingFees The amount of shares to redeem
	 * @param receiver The address of the receiver
	 * @param owner The address of the owner
	 * @return assetsIncludingFees Array with proportional amounts of reserve tokens to be paid out
	 */
	function redeemProportional(uint256 sharesIncludingFees, address receiver, address owner) public virtual override returns (uint256[] memory) {
		owner.requireNonZeroAddress();
		receiver.requireNonZeroAddress();
		before_nonReentrant();
		if (msg.sender != owner) _spendAllowance(owner, msg.sender, sharesIncludingFees);
		uint256 reportedFreeFunds = DynaVaultLib.reportAllReserves();
		DynaVaultLib.checkRedeem(sharesIncludingFees, owner, reportedFreeFunds);
		uint256[] memory toRedeem = DynaVaultLib.calcRedeemProportional(sharesIncludingFees);
		_burn(owner, sharesIncludingFees);
		DynaVaultLib.transferProportional(receiver, toRedeem);
		after_nonReentrant();
		return toRedeem;
	}

	/**
	 * @notice Preview of redeem proportional
	 * @param sharesIncludingFees Amount of shares to redeem
	 * @param _snapshot Snapshot used for the simulation
	 * @return assets Array with proportional amounts of reserve tokens
	 */
	function previewRedeemProportional(
		uint256 sharesIncludingFees,
		IVaultSimulatorAPI.VaultSnapshot memory _snapshot
	) external view virtual override returns (uint256[] memory) {
		return IVaultSimulatorAPI(simulator).simulatedRedeemProportional(sharesIncludingFees, _snapshot);
	}

	/**
	 * @notice Redeems an amount of shares paid out in proportional amounts of reserve tokens with slippage checking
	 * @param shares The amount of shares to redeem
	 * @param receiver The address of the receiver
	 * @param owner The address of the owner
	 * @param minAssets An array with min amounts of assets
	 * @return assets An array with proportional amounts of reserve tokens to be paid out
	 */
	function redeemProportionalCheckSlippage(
		uint256 shares,
		address receiver,
		address owner,
		uint256[] memory minAssets
	) public virtual override returns (uint256[] memory) {
		owner.requireNonZeroAddress();
		receiver.requireNonZeroAddress();
		uint256[] memory assets = redeemProportional(shares, receiver, owner);
		DynaVaultErrors.checkSlippageAbove(assets, minAssets);
		return assets;
	}

	/**
	 * @notice Returns the address of the vault manager
	 * @return manager The address of the vault manager
	 */
	function manager() public view returns (address) {
		return VaultConfigLib.manager();
	}

	/**
	 * @notice Returns the address of the router registry
	 * @return routerRegistryAddress The address of the  router registry
	 */
	function routerRegistry() public view override returns (IDynaRouterRegistryAPI) {
		return IDynaRouterRegistryAPI(VaultConfigLib.routerRegistry());
	}

	/**
	 * @notice Issues shares for fees
	 * @notice deltaTotalAssets is in reference asset, used when there is profit in strategies to compensate balances in calculations
	 * @param to The address of fee receiver
	 * @param feeAmount The amount of fee in feeToken
	 * @param feeToken The address of fee token
	 * @param deltaTotalAssets The delta of total assets
	 * @return shares The amount of shares minted
	 */
	function issueSharesForFeeAmount(address to, uint256 feeAmount, address feeToken, uint256 deltaTotalAssets) external override returns (uint256) {
		if (address(msg.sender) != manager()) revert DynaVaultErrors.NotAuthorized();
		uint256 shares = DynaVaultLib.calcSharesForFeeAmount(feeAmount, feeToken, deltaTotalAssets);
		_mint(to, shares);
		return shares;
	}

	/**
	 * @dev Deposit/mint common workflow.
	 * @notice Private function called during deposit
	 * @param caller The address of caller
	 * @param receiver The address of receiver
	 * @param assetsIncludingFees The assets that receiver will get
	 * @param _sharesWithoutFees The shares that are burned
	 */
	function _deposit(address caller, address receiver, uint256 assetsIncludingFees, uint256 _sharesWithoutFees) private {
		uint256 fee = DynaVaultLib.beforeMint(caller, assetsIncludingFees);
		_mint(receiver, _sharesWithoutFees);
		DynaVaultLib.afterMint(caller, receiver, assetsIncludingFees, _sharesWithoutFees, fee);
	}

	/**
	 * @dev Withdraw/redeem common workflow.
	 * @notice Private function called during withdraw
	 * @param caller The address of caller
	 * @param receiver The address of receiver
	 * @param owner The address of owner
	 * @param assetsNotIncludingFees The assets that receiver will get
	 * @param sharesIncludingFees The amount of shares to burn
	 */
	function _withdraw(address caller, address receiver, address owner, uint256 assetsNotIncludingFees, uint256 sharesIncludingFees) private {
		if (caller != owner) _spendAllowance(owner, caller, sharesIncludingFees);
		uint256 assetsToWithdraw = DynaVaultLib.beforeBurn(assetsNotIncludingFees, sharesIncludingFees);
		_burn(owner, sharesIncludingFees);
		DynaVaultLib.afterBurn(caller, receiver, owner, assetsToWithdraw, sharesIncludingFees);
	}

	/**
	 * @notice Returns the value of one share in deposit token
	 * @return pricePerShare value of one share in deposit token
	 */
	function pricePerShare() external view returns (uint256) {
		return IVaultSimulatorAPI(simulator).assetsPerShare();
	}

	/**
	 * @notice Returns the minimum amount of tokens that can be deposited
	 * @return minDepositLimit The minimum amount possible to deposit
	 */
	function minDepositLimit() external view returns (uint256) {
		return DynaVaultLib.minDepositLimit();
	}

	/**
	 * @notice Returns the max value of the tokens in the vault
	 * @return maxTotalAssets The max amount of assets in vault
	 */
	function maxTotalAssets() external view returns (uint256) {
		return DynaVaultLib.maxTotalAssets();
	}

	/**
	 * @notice Returns the max amount possible to deposit
	 * @return maxDepositLimit The max amount of tokens that can be deposited
	 */
	function maxDepositLimit() external view returns (uint256) {
		return DynaVaultLib.maxDepositLimit();
	}

	/**
	 * @notice Set deposit limits
	 * @param newMinDepositAssets The new minimum deposit amount limit
	 * @param newMaxTotalAssets The new max total assets limit
	 */
	function setDepositLimits(uint256 newMinDepositAssets, uint256 newMaxTotalAssets) external {
		DynaVaultLib.setDepositLimits(newMinDepositAssets, newMaxTotalAssets);
	}

	/**
	 * @notice Transfers fees to a receiver
	 * @param to The address of the fee receiver
	 * @param amount The amount of shares to send
	 */
	function feeTransfer(address to, uint256 amount) external override {
		VaultConfigLib.onlyManager();
		_transfer(address(this), to, amount);
	}

	/**
	 * @notice Set the DynaRouterRegistry address
	 * @param routerRegistryAddress The address of the new router registry
	 */
	function setRouterRegistry(address routerRegistryAddress) external {
		VaultConfigLib.setRouterRegistry(routerRegistryAddress);
	}

	/**
	 * @notice Used to fetch swap data used when calling swap
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount to swap
	 * @param tokenOut The address of the output token
	 * @return amountOut The expected amount out from swap
	 * @return selectedRouter The address of router to use
	 * @return swapData The data used in swap
	 */
	function previewSwap(
		address tokenIn,
		uint256 amountIn,
		address tokenOut
	) external view returns (uint256 amountOut, address selectedRouter, bytes32[] memory swapData) {
		return VaultRouterLib.previewSwap(tokenIn, amountIn, tokenOut);
	}

	/**
	 * @notice Swap function to be called by vault management to swap and change target weights
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min expected amount out from swap
	 * @param selectedRouter The address of router to use
	 * @param swapData The data used for the swap
	 */
	function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut, address selectedRouter, bytes32[] memory swapData) external {
		before_nonReentrant();
		VaultRouterLib.swap(tokenIn, amountIn, tokenOut, minAmountOut, selectedRouter, swapData);
		after_nonReentrant();
	}

	/**
	 * @notice Swap with reporting of the tokens swapped
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount of input token to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min expected amount out from swap
	 * @param selectedRouter The address of router to use
	 * @param swapData The swapData from previewSwap
	 */
	function swapAndReport(
		address tokenIn,
		uint256 amountIn,
		address tokenOut,
		uint256 minAmountOut,
		address selectedRouter,
		bytes32[] memory swapData
	) external {
		before_nonReentrant();
		VaultRouterLib.swapAndReport(tokenIn, amountIn, tokenOut, minAmountOut, selectedRouter, swapData);
		after_nonReentrant();
	}

	/**
	 * @notice Sets the reference asset oracle address
	 * @param referenceAssetOracleAddress The address of the new reference asset oracle
	 */
	function setReferenceAssetOracle(address referenceAssetOracleAddress) external {
		VaultConfigLib.setReferenceAssetOracle(referenceAssetOracleAddress);
	}

	/**
	 * @notice Returns the address of the configured reference oracle
	 * @return referenceAssetOracle The address of the reference oracle
	 */
	function referenceAssetOracle() external view returns (address) {
		return VaultConfigLib.referenceAssetOracle();
	}

	/**
	 * @notice Returns the reference asset address
	 * @return referenceAsset The address of the reference assets
	 */
	function referenceAsset() external view returns (address) {
		return VaultConfigLib.referenceAsset();
	}

	/**
	 * @notice Returns the current max loss limit
	 * @return maxLoss The current max loss limit
	 */

	function maxLoss() external view returns (uint256) {
		return VaultConfigLib.maxLoss();
	}

	/**
	 * @notice Sets the max loss limit
	 * @param _maxLoss The new max loss limit
	 */
	function setMaxLoss(uint256 _maxLoss) external {
		VaultConfigLib.setMaxLoss(_maxLoss);
	}

	/**
	 * @notice Approve manager for swapping token
	 * @param tokenAddress Address of the token to approve
	 */
	function approveAddedToken(address tokenAddress) external {
		VaultConfigLib.approveAddedToken(tokenAddress);
	}

	/**
	 * @notice Reset allowance of manager for swapping token
	 * @param tokenAddress The address of the token to approve
	 */
	function resetRemovedTokenAllowance(address tokenAddress) external {
		VaultConfigLib.resetRemovedTokenAllowance(tokenAddress);
	}

	/**
	 * @notice This a swap function to be called by the vault manager contract to rebalance, which does not change target depositDebtRatio weights
	 * @param tokenIn The address of the input token
	 * @param amountIn The amount to swap
	 * @param tokenOut The address of the output token
	 * @param minAmountOut The min expected amount out from swap
	 * @return amountOut The amount of tokenOut from swap
	 */
	function doSwap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut) external returns (uint256 amountOut) {
		return VaultRouterLib.doSwap(tokenIn, amountIn, tokenOut, minAmountOut);
	}

	/**
	 * @notice Calculates shares for fees with given values for total supply and total assets
	 * @param feeAmount The amount for fees
	 * @param feeToken The address of the fee token
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
	) external view returns (uint256 feeShares) {
		return
			DynaVaultLib.calcSharesForFeeAmountUsingGivenTotalSupplyAndTotalAssets(feeAmount, feeToken, deltaTotalAssets, givenTotalSupply, givenTotalAssets);
	}

	/**
	 * @notice Calculates shares for fees with given values for total supply and free funds
	 * @param feeAmount The amount for fee
	 * @param feeToken The address of the fee token
	 * @param givenTotalSupply The amount of total supply to use in calculation
	 * @param givenFreeFunds The amount of free funds to use in calculation
	 * @return feeShares The amount of shares to mint for fees
	 */
	function calcSharesForFeeAmountUsingGivenTotalSupplyAndFreeFunds(
		uint256 feeAmount,
		address feeToken,
		uint256 givenTotalSupply,
		uint256 givenFreeFunds
	) external view returns (uint256 feeShares) {
		return DynaVaultLib.calcSharesForFeeAmountUsingGivenTotalSupplyAndFreeFunds(feeAmount, feeToken, givenTotalSupply, givenFreeFunds);
	}

	/**
	 * @notice Returns value of token in quote asset
	 * @param base The address of the base token
	 * @param amount The amount of base token
	 * @param quote The address of the quote token
	 * @return value The value of the amount of base token in quote token
	 */
	function tokenValueInQuoteAsset(address base, uint256 amount, address quote) external view returns (uint256 value) {
		return DynaVaultLib.tokenValueInQuoteAsset(base, amount, quote);
	}

	/**
	 * @dev Simulates the calculation of how many shares should be minted for fees
	 * @param feeAmount The amount of fees
	 * @param feeToken The token used to calculate fees
	 * @param deltaTotalAssets The vault profit
	 * @param snapshot The current vault snapshot
	 * @return Updated snapshot with new total supply
	 */
	function simulatedIssueSharesForFeeAmount(
		uint256 feeAmount,
		address feeToken,
		uint256 deltaTotalAssets,
		IVaultSimulatorAPI.VaultSnapshot memory snapshot
	) external view returns (IVaultSimulatorAPI.VaultSnapshot memory) {
		return IVaultSimulatorAPI(simulator).simulatedIssueSharesForFeeAmount(feeAmount, feeToken, deltaTotalAssets, snapshot);
	}

	/**
	 * @notice Withdraw token debt from strategies
	 * @param tokenAddress The address of the token
	 * @param valueToWithdraw The amount to withdraw
	 */
	function withdrawTokenDebtFromStrategies(address tokenAddress, uint256 valueToWithdraw) external returns (uint256 totalLoss, uint256 totalWithdrawn) {
		return DynaVaultLib.withdrawTokenDebtFromStrategies(tokenAddress, valueToWithdraw);
	}
}
