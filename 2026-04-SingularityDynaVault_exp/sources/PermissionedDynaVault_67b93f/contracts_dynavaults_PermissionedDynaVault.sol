// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "./DynaVault.sol";
import "./VaultConfigLib.sol";

/**
 * @title Permissioned Vault
 * @notice Wraps DynaVault to only allow permitted users to deposit and withdraw
 */
contract PermissionedDynaVault is DynaVault {
	bytes32 private constant PERMISSION_ADMIN = keccak256("PERMISSION_ADMIN");
	bytes32 private constant PERMITTED_USER = keccak256("PERMITTED_USER");

	bool public permissionDisabled;

	event UpdatedPermissionDisabled(address caller, bool newState);

	/**
	 * @notice Initializes the permissioned vault
	 * @param nameOverride The vault name
	 * @param symbolOverride The vault symbol
	 * @param managerAddress The address of the vault manager
	 * @param referenceAssetOracleAddress The address of the reference asset oracle
	 * @param dynaRouterRegistryAddress The address of the DynaRouter registry
	 * @param ownerAddress The address of the owner
	 * @param vaultSimulatorAddress The address of the vault simulator
	 */
	function initialize(
		string memory nameOverride,
		string memory symbolOverride,
		address managerAddress,
		address referenceAssetOracleAddress,
		address dynaRouterRegistryAddress,
		address ownerAddress,
		address vaultSimulatorAddress
	) public override {
		DynaVault.initialize(
			nameOverride,
			symbolOverride,
			managerAddress,
			referenceAssetOracleAddress,
			dynaRouterRegistryAddress,
			ownerAddress,
			vaultSimulatorAddress
		);
		_setRoleAdmin(PERMITTED_USER, PERMISSION_ADMIN);
	}

	/**
	 * @notice Toggles if the vault requires permission
	 * @param newState The new permission state
	 */
	function setPermissionDisabled(bool newState) external {
		VaultConfigLib.onlyGovernance();
		permissionDisabled = newState;
		emit UpdatedPermissionDisabled(msg.sender, newState);
	}

	/**
	 * @notice Checks if a vault requires permission
	 */
	function checkPermission() private view {
		if (!permissionDisabled) _checkRole(PERMITTED_USER);
	}

	/** @dev See {IERC5143-mint} */
	function mint(uint256 sharesNotIncludingFees, address receiver) public virtual override returns (uint256 assetsIncludingFees) {
		checkPermission();
		return DynaVault.mint(sharesNotIncludingFees, receiver);
	}

	/** @dev See {IERC5143-mint} */
	function mintCheckSlippage(uint256 shares, address receiver, uint256 maxAssets) public virtual override returns (uint256) {
		checkPermission();
		return DynaVault.mintCheckSlippage(shares, receiver, maxAssets);
	}

	/** @dev See {IERC5143-mint} */
	function deposit(uint256 assetsIncludingFees, address receiver) public virtual override returns (uint256 sharesNotIncludingFees) {
		checkPermission();
		return DynaVault.deposit(assetsIncludingFees, receiver);
	}

	/** @dev See {IERC5143-mint} */
	function depositCheckSlippage(uint256 assets, address receiver, uint256 minShares) public virtual override returns (uint256) {
		checkPermission();
		return DynaVault.depositCheckSlippage(assets, receiver, minShares);
	}

	/** @dev See {IERC5143-mint} */
	function withdraw(uint256 assetsNotIncludingFees, address receiver, address owner) public virtual override returns (uint256 sharesIncludingFees) {
		checkPermission();
		return DynaVault.withdraw(assetsNotIncludingFees, receiver, owner);
	}

	/** @dev See {IERC5143-mint} */
	function withdrawCheckSlippage(uint256 assets, address receiver, address owner, uint256 maxShares) public virtual override returns (uint256) {
		checkPermission();
		return DynaVault.withdrawCheckSlippage(assets, receiver, owner, maxShares);
	}

	/** @dev See {IERC5143-mint} */
	function redeem(uint256 sharesIncludingFees, address receiver, address owner) public virtual override returns (uint256 assetsNotIncludingFees) {
		checkPermission();
		return DynaVault.redeem(sharesIncludingFees, receiver, owner);
	}

	/** @dev See {IERC5143-mint} */
	function redeemCheckSlippage(uint256 shares, address receiver, address owner, uint256 minAssets) public virtual override returns (uint256) {
		checkPermission();
		return DynaVault.redeemCheckSlippage(shares, receiver, owner, minAssets);
	}

	/**
	 * @notice Redeems an amount of shares paid out in proportional amounts of reserve tokens
	 * @param sharesIncludingFees The amount of shares to redeem
	 * @param receiver The address of the receiver
	 * @param owner The address of the owner
	 * @return assetsIncludingFees Array with proportional amounts of reserve tokens to be paid out
	 */
	function redeemProportional(uint256 sharesIncludingFees, address receiver, address owner) public virtual override returns (uint256[] memory) {
		checkPermission();
		return DynaVault.redeemProportional(sharesIncludingFees, receiver, owner);
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
		checkPermission();
		return DynaVault.redeemProportionalCheckSlippage(shares, receiver, owner, minAssets);
	}
}
