// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./DynaVaultErrors.sol";
import "./interfaces/IVaultManagerAPI.sol";
import "./interfaces/IReferenceAssetOracle.sol";
import "./utils/Checks.sol";

/**
 * @title VaultConfigLib is part of DynaVault and explicitly handles the storage of contract addresses.
 * @notice It includes several necessary setter functions which allow governance to adjust max loss/deviation variables.
 */
library VaultConfigLib {
	using Checks for address;
	using Math for uint256;
	using SafeERC20 for IERC20;

	/// @dev The storage slot follows EIP1967 to avoid storage collision
	bytes32 private constant CONFIG_STORAGE_POSITION = bytes32(uint256(keccak256("DynaVault.configStorage")) - 1);
	uint256 private constant DEFAULT_MAX_LOSS = 100; // default 1.00% max loss protection
	uint256 private constant MAX_LOSS_LIMIT = 2000; // 20.00% max loss protection

	struct ConfigStorage {
		address token;
		address manager;
		address routerRegistry;
		address referenceAssetOracle;
		address referenceAsset;
		uint256 depositDecimals;
		uint256 maxLoss; // max loss BPS for loss protection
	}

	event UpdatedRouterRegistry(address newDynaRouterRegistry);
	event UpdatedReferenceAssetOracle(address referenceAssetOracle);
	event UpdatedMaxLoss(uint256 newMaxLoss);

	/**
	 * @notice Returns the library storage
	 * @return cs Storage pointer for accessing the state variables
	 */
	function configStorage() private pure returns (ConfigStorage storage cs) {
		bytes32 position = CONFIG_STORAGE_POSITION;
		assembly {
			cs.slot := position
		}
	}

	/**
	 * @notice Returns the address of the vault manager
	 * @return manager The address of the vault manager
	 */
	function manager() external view returns (address) {
		return configStorage().manager;
	}

	/**
	 * @notice Returns the address of the deposit token
	 * @return asset The address of the deposit token
	 */
	function asset() external view returns (address) {
		return configStorage().token;
	}

	/**
	 * @notice Returns the address of the DynaRouter registry
	 * @return routerRegistry The address of the DynaRouter registry
	 */
	function routerRegistry() external view returns (address) {
		return configStorage().routerRegistry;
	}

	/**
	 * @notice Returns the address of the reference oracle
	 * @return referenceAssetOracle The address of the reference oracle
	 */
	function referenceAssetOracle() external view returns (address) {
		return configStorage().referenceAssetOracle;
	}

	/**
	 * @notice Returns the decimals of the deposit token
	 * @return decimals The decimals of the deposit token
	 */
	function depositDecimals() external view returns (uint256) {
		return configStorage().depositDecimals;
	}

	/**
	 * @notice Initializes the config library
	 * @param managerAddress The address of the manager
	 * @param routerRegistryAddress The address of the DynaRouter registry
	 * @param referenceAssetOracleAddress The address of the reference asset oracle
	 */
	function initialize(address managerAddress, address routerRegistryAddress, address referenceAssetOracleAddress) external {
		managerAddress.requireNonZeroAddress();
		routerRegistryAddress.requireNonZeroAddress();
		referenceAssetOracleAddress.requireNonZeroAddress();
		ConfigStorage storage _storage = configStorage();
		_storage.manager.isNotAlreadyInitialized();
		_storage.manager = managerAddress;
		_storage.token = IVaultManagerAPI(managerAddress).token();
		_storage.depositDecimals = IERC20Metadata(_storage.token).decimals();
		IERC20(_storage.token).safeIncreaseAllowance(managerAddress, type(uint256).max); // set max allowance assuming it was 0
		_storage.routerRegistry = routerRegistryAddress;
		_storage.referenceAssetOracle = referenceAssetOracleAddress;
		address _referenceAsset = IReferenceAssetOracle(referenceAssetOracleAddress).referenceAsset();
		_storage.referenceAsset = _referenceAsset;
		_storage.maxLoss = DEFAULT_MAX_LOSS;
	}

	/**
	 * @notice checks if caller is manager
	 */
	function onlyManager() external view {
		if (msg.sender != configStorage().manager) {
			revert DynaVaultErrors.NotAuthorized();
		}
	}

	/**
	 * @notice checks if caller has governance role
	 */
	function onlyGovernance() external {
		IVaultManagerAPI(configStorage().manager).checkGovernance(msg.sender);
	}

	/**
	 * @notice Sets the DynaRouter registry address
	 * @param routerRegistryAddress The address of the new DynaRouter registry
	 */
	function setRouterRegistry(address routerRegistryAddress) external {
		IVaultManagerAPI(configStorage().manager).checkGovernance(msg.sender);
		routerRegistryAddress.requireNonZeroAddress();
		configStorage().routerRegistry = routerRegistryAddress;
		emit UpdatedRouterRegistry(routerRegistryAddress);
	}

	/**
	 * @notice Sets the reference asset oracle address
	 * @param upgradedReferenceAssetOracleAddress The address of the new reference asset oracle
	 */
	function setReferenceAssetOracle(address upgradedReferenceAssetOracleAddress) external {
		IVaultManagerAPI(configStorage().manager).checkGovernance(msg.sender);
		upgradedReferenceAssetOracleAddress.requireNonZeroAddress();
		ConfigStorage storage _storage = configStorage();
		_storage.referenceAssetOracle = upgradedReferenceAssetOracleAddress;
		address _referenceAsset = IReferenceAssetOracle(upgradedReferenceAssetOracleAddress).referenceAsset();
		if (_storage.referenceAsset != _referenceAsset) {
			revert DynaVaultErrors.NotSameReferenceAsset();
		}
		_storage.referenceAsset = _referenceAsset;
		emit UpdatedReferenceAssetOracle(upgradedReferenceAssetOracleAddress);
	}

	/**
	 * @notice Returns the reference asset address
	 * @return referenceAsset The address of the reference assets
	 */
	function referenceAsset() external view returns (address) {
		return configStorage().referenceAsset;
	}

	/**
	 * @notice Returns the current max loss limit
	 * @return maxLoss The current max loss limit
	 */
	function maxLoss() external view returns (uint256) {
		return configStorage().maxLoss;
	}

	/**
	 * @notice Sets max loss
	 * @param newMaxLoss The new max loss limit
	 */
	function setMaxLoss(uint256 newMaxLoss) external {
		IVaultManagerAPI(configStorage().manager).checkGovernance(msg.sender);
		if (newMaxLoss > MAX_LOSS_LIMIT) {
			revert DynaVaultErrors.MaxLossLimit();
		}
		configStorage().maxLoss = newMaxLoss;
		emit UpdatedMaxLoss(newMaxLoss);
	}

	/**
	 * @notice Approve manager for swapping token
	 * @param tokenAddress The address of the token to approve
	 */
	function approveAddedToken(address tokenAddress) external {
		address _manager = configStorage().manager;
		if (msg.sender != _manager) {
			revert DynaVaultErrors.NotAuthorized();
		}
		if (IERC20(tokenAddress).allowance(address(this), _manager) == 0) IERC20(tokenAddress).safeIncreaseAllowance(_manager, type(uint256).max);
	}

	/**
	 * @notice Reset manager allowance for swapping token to 0
	 * @param tokenAddress The address of the token to approve
	 */
	function resetRemovedTokenAllowance(address tokenAddress) external {
		address _manager = configStorage().manager;
		if (msg.sender != _manager) {
			revert DynaVaultErrors.NotAuthorized();
		}
		IERC20(tokenAddress).safeApprove(_manager, 0);
	}
}
