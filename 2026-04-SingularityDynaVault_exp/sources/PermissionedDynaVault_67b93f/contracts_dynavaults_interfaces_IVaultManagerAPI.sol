// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./IVaultSimulatorAPI.sol";

struct Fees {
	uint256 managementFee;
	uint256 performanceFee;
	uint256 depositFee;
	uint256 redemptionFee;
	address managementFeeWallet;
	address performanceFeeWallet;
	address depositFeeWallet;
	address redemptionFeeWallet;
}

struct TokenStats {
	uint256 tokenIdle /* Amount of tokens that are in the vault (reserves) */;
	uint256 tokenDebt /* Amount of tokens that all strategies have borrowed  */;
	uint256 depositDebt; // Amount of deposit tokens used
	uint256 depositDebtRatio; // Target ratio of deposit tokens
	uint256 totalProfit;
	uint256 totalLoss;
	uint256 lastReport;
	uint256 lastReportedValue;
	uint256 watermark;
}

struct StrategyParams {
	address want;
	uint256 performanceFee;
	uint256 activation;
	uint256 debtRatio;
	uint256 minDebtPerHarvest;
	uint256 maxDebtPerHarvest;
	uint256 lastReport;
	uint256 totalDebt;
	uint256 totalGain;
	uint256 totalLoss;
}

interface IVaultManagerAPI {
	function apiVersion() external pure returns (string memory);

	function token() external view returns (address);

	function nrOfTokens() external view returns (uint256);

	function tokens(uint256 index) external view returns (address);

	function tokenIndex(address token) external view returns (uint256);

	function totalIdle(uint256 index) external view returns (uint256);

	function totalDebt(uint256 index) external view returns (uint256);

	function strategies(address _strategy) external view returns (StrategyParams memory);

	function tokenStats(address tokenAddress) external view returns (TokenStats memory);

	function tokenIdleDebt(address tokenAddress) external view returns (uint256 tokenIdle, uint256 tokenDebt);

	function getFees() external view returns (Fees memory);

	function totalTokenAssets() external view returns (uint256 total);

	function totalAssets() external view returns (uint256 total);

	function minDepositLimit() external view returns (uint256);

	function maxDepositLimit() external view returns (uint256);

	/** calculate new strategy debt ratio based on investment amount
	 *  and call strategy harvest to take fees and adjust position */
	function investStrategy(address strategy, uint256 amount) external;

	/**
	 * View how much the Vault would increase this Strategy's borrow limit,
	 * based on its present performance (since its last report). Can be used to
	 * determine expectedReturn in your Strategy.
	 */
	function creditAvailable() external view returns (uint256);

	function creditAvailable(address strategy) external view returns (uint256);

	/**
	 * View how much the Vault would like to pull back from the Strategy,
	 * based on its present performance (since its last report). Can be used to
	 * determine expectedReturn in your Strategy.
	 */
	function debtOutstanding() external view returns (uint256);

	function debtOutstanding(address strategy) external view returns (uint256);

	/**
	 * View how much the Vault expect this Strategy to return at the current
	 * block, based on its present performance (since its last report). Can be
	 * used to determine expectedReturn in your Strategy.
	 */
	function expectedReturn(address _strategy) external view returns (uint256);

	/**
	 * This is the main contact point where the Strategy interacts with the
	 * Vault. It is critical that this call is handled as intended by the
	 * Strategy. Therefore, this function will be called by BaseStrategy to
	 * make sure the integration is correct.
	 */
	function reportStrategy(uint256 _gain, uint256 _loss, uint256 _debtPayment) external returns (uint256);

	/**
	 * This function should only be used in the scenario where the Strategy is
	 * being retired but no migration of the positions are possible, or in the
	 * extreme scenario that the Strategy needs to be put into "Emergency Exit"
	 * mode in order for it to exit as quickly as possible. The latter scenario
	 * could be for any reason that is considered "critical" that the Strategy
	 * exits its position as fast as possible, such as a sudden change in
	 * market conditions leading to losses, or an imminent failure in an
	 * external dependency.
	 */
	function revokeStrategy(address strategy) external;

	/**
	 * This will resurrect a strategy when a revoked strategy should be brought back
	 */
	function resurrectStrategy(address strategy) external;

	/**
	 * View the governance address of the Vault to assert privileged functions
	 * can only be called by governance. The Strategy serves the Vault, so it
	 * is subject to governance defined by the Vault.
	 */
	function governance() external view returns (address);

	/**
	 * View the management address of the Vault to assert privileged functions
	 * can only be called by management. The Strategy serves the Vault, so it
	 * is subject to management defined by the Vault.
	 */
	function management() external view returns (address);

	function vault() external view returns (address);

	/**
	 * View the guardian address of the Vault to assert privileged functions
	 * can only be called by guardian. The Strategy serves the Vault, so it
	 * is subject to guardian defined by the Vault.
	 */
	function guardian() external view returns (address);

	function depositIdle(address tokenAddress, uint256 _assets) external;

	function withdrawIdle(address tokenAddress, uint256 _assets) external;

	function setTotalIdle(address tokenAddress, uint256 _assets) external;

	function depositDepositToken(uint256 _depositAmount, uint256 _feeAmount) external;

	function withdrawDepositToken(uint256 _withdrawAmount) external;

	function freeFunds() external view returns (uint256);

	function strategyDebt(address strategy) external view returns (uint256);

	function getTokenStrategies(address tokenAddress) external view returns (address[] memory queue);

	function reportReserve(address tokenAddress) external;

	function reportReserveFromVault(address token) external;

	function reportAllReservesFromVault() external returns (uint256 reportedFreeFunds);

	function reportLoss(address strategy, uint256 loss) external;

	function decreaseStrategyDebt(address strategy, uint256 withdrawn) external;

	function updateDebtAfterSwap(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut, bool updateRatio) external;

	function initialize(
		address _vault,
		address tokenAddress,
		address _governance,
		address _management,
		address _guardian,
		address _managementFeeWallet,
		address _performanceFeeWallet,
		address _owner
	) external;

	function checkManagementOrGovernance(address user) external;

	function checkGovernance(address user) external;

	function onlyVaultOrManagement() external view;

	function lastLockedProfitRatio() external view returns (uint256);

	function lastLockedProfitDegradation() external view returns (uint256);

	function lockedProfit() external view returns (uint256);

	function lockedProfitDegradationRates() external view returns (uint256, uint256);

	function unlockedFundsRatio() external view returns (uint256);

	function ethToWant(uint256 _amount, address _weth) external view returns (uint256);

	function tokenExists(address tokenAddress) external view returns (bool);

	function simulatedReportAllReserves(IVaultSimulatorAPI.VaultSnapshot memory snapshot) external view returns (IVaultSimulatorAPI.VaultSnapshot memory);

	function simulateUnlockedFundsRatio(IVaultSimulatorAPI.VaultSnapshot memory snapshot) external view returns (uint256);

	function simulatedFreeFunds(IVaultSimulatorAPI.VaultSnapshot memory snapshot) external view returns (uint256);

	function takeStrategiesSnapshot(address tokenAddress) external view returns (IVaultSimulatorAPI.VaultStrategySnapshot[] memory snapshots);
}
