// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.30;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {DynamicSet} from "@solarity/solidity-lib/libs/data-structures/DynamicSet.sol";

/**
 * @title IPermissionsManager
 * @notice A foundational interface that establishes a common structure for modules
 * enabling delegated and permissioned actions on behalf of a Gnosis Safe. It defines
 * standard data structures, errors, and events for tracking permissioned approvals.
 */
interface IPermissionsManager {
    /**
     * @notice Thrown when a required address parameter is the zero address (0x0).
     */
    error ZeroAddress();

    /**
     * @notice Thrown when an address is not recognized as a valid module.
     * @param module The address that failed the module check.
     */
    error NotAModule(address module);

    /**
     * @notice Thrown when an attempt is made to add a delegate who is already registered.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate who already exists.
     */
    error DelegateAlreadyExists(address safe, address delegate);

    /**
     * @notice Thrown when an action is performed on a delegate who is not registered.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the non-existent delegate.
     */
    error DelegateDoesNotExist(address safe, address delegate);

    /**
     * @notice Thrown when an attempt is made to grant a permission that a delegate already holds.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate.
     * @param module The address of the module for which permission is being granted.
     * @param permission The string identifier of the permission that already exists.
     */
    error PermissionAlreadyGranted(
        address safe,
        address delegate,
        address module,
        string permission
    );

    /**
     * @notice Thrown when an attempt is made to revoke a permission that a delegate does not have.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate.
     * @param module The address of the module for which permission is being revoked.
     * @param permission The string identifier of the permission that does not exist.
     */
    error PermissionDoesNotExist(
        address safe,
        address delegate,
        address module,
        string permission
    );

    /**
     * @notice Thrown when a delegate attempts an action for which they lack the required permission.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate.
     * @param permission The bytes32 hash of the permission that was denied.
     */
    error PermissionDenied(address safe, address delegate, bytes32 permission);

    /**
     * @notice Emitted when a new delegate is successfully added to a safe.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the new delegate.
     */
    event DelegateAdded(address indexed safe, address indexed delegate);

    /**
     * @notice Emitted when a delegate is successfully removed from a safe.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the removed delegate.
     */
    event DelegateRemoved(address indexed safe, address indexed delegate);

    /**
     * @notice Emitted when a specific permission is successfully granted to a delegate.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate receiving the permission.
     * @param module The address of the module associated with the permission.
     * @param permission The string identifier of the permission that was granted.
     */
    event PermissionGranted(
        address indexed safe,
        address indexed delegate,
        address module,
        string permission
    );

    /**
     * @notice Emitted when a specific permission is successfully revoked from a delegate.
     * @param safe The address of the Gnosis Safe.
     * @param delegate The address of the delegate from whom the permission was revoked.
     * @param module The address of the module associated with the permission.
     * @param permission The string identifier of the permission that was revoked.
     */
    event PermissionRevoked(
        address indexed safe,
        address indexed delegate,
        address module,
        string permission
    );

    /**
     * @notice A struct to encapsulate a delegate's address and their associated module permissions.
     * @param delegate The address of the delegate.
     * @param modulesInfo An array of `ModulePermissionsInfo` structs containing module and permission details.
     */
    struct DelegateInfo {
        address delegate;
        ModulePermissionsInfo[] modulesInfo;
    }

    /**
     * @notice A struct to hold the permissions granted to a delegate for a specific module.
     * @param module The address of the module.
     * @param permissions An array of string identifiers for the permissions granted.
     */
    struct ModulePermissionsInfo {
        address module;
        string[] permissions;
    }

    /**
     * @notice A struct to pair a module's address with a specific permission string.
     * @param moduleAddr The address of the module.
     * @param permission The string identifier of the permission.
     */
    struct PermissionEntry {
        address moduleAddr;
        string permission;
    }

    /**
     * @notice A struct to store all permissions data for a single delegate.
     * @param modules A set of module addresses for which the delegate has permissions.
     * @param modulePermissions A mapping from a module address to a set of permission strings.
     */
    struct DelegatePermissionsData {
        EnumerableSet.AddressSet modules;
        mapping(address => DynamicSet.StringSet) modulePermissions;
    }

    /**
     * @notice A struct to store all delegate permissions data for a single account.
     * @param delegators A set of delegate addresses for the account.
     * @param delegatorsData A mapping from a delegate address to their `DelegatePermissionsData`.
     */
    struct AccountData {
        EnumerableSet.AddressSet delegators;
        mapping(address => DelegatePermissionsData) delegatorsData;
    }

    /**
     * @notice Grants an array of permissions to a specified delegate.
     * @param delegate The address of the delegate to whom permissions are being granted.
     * @param permissions An array of `PermissionEntry` structs, each specifying a module and permission string to be granted.
     */
    function grantPermissions(address delegate, PermissionEntry[] calldata permissions) external;

    /**
     * @notice Revokes an array of permissions from a specified delegate.
     * @param delegate The address of the delegate from whom permissions are being revoked.
     * @param permissions An array of `PermissionEntry` structs, each specifying a module and permission string to be revoked.
     */
    function revokePermissions(address delegate, PermissionEntry[] calldata permissions) external;

    /**
     * @notice Retrieves information about all delegates associated with a given account.
     * @param account The address of the account (e.g., a Gnosis Safe).
     * @return delegatorsInfo An array of `DelegateInfo` structs,
     * each containing the delegate's address and their module permissions.
     */
    function getAccountDelegatorsInfo(
        address account
    ) external view returns (DelegateInfo[] memory delegatorsInfo);

    /**
     * @notice Retrieves all permissions granted to a specific delegate for all modules.
     * @param account The address of the account that owns the permissions.
     * @param delegate The address of the delegate to query.
     * @return modulesInfo An array of `ModulePermissionsInfo` structs,
     * providing the module address and its granted permissions.
     */
    function getModulesPermissionsInfo(
        address account,
        address delegate
    ) external view returns (ModulePermissionsInfo[] memory modulesInfo);

    /**
     * @notice Checks if a specific delegate has a given permission.
     * @param account The address of the account (e.g., a Gnosis Safe).
     * @param delegate The address of the delegate to check.
     * @param permission A `PermissionEntry` struct representing the permission to be checked.
     * @return `true` if the delegate has the permission, `false` otherwise.
     */
    function hasPermission(
        address account,
        address delegate,
        PermissionEntry calldata permission
    ) external view returns (bool);

    /**
     * @notice Checks if a given address is a registered delegate for a specific account.
     * @param account The address of the account (e.g., a Gnosis Safe).
     * @param delegate The address to check for delegate status.
     * @return `true` if the address is a delegate for the account, `false` otherwise.
     */
    function hasDelegate(address account, address delegate) external view returns (bool);

    /**
     * @notice Checks if a delegate has any permissions associated with a specific module.
     * @param account The address of the account (e.g., a Gnosis Safe).
     * @param delegate The address of the delegate to check.
     * @param module The address of the module to check for permissions.
     * @return `true` if the delegate has permissions for the module, `false` otherwise.
     */
    function hasModulePermission(
        address account,
        address delegate,
        address module
    ) external view returns (bool);
}
