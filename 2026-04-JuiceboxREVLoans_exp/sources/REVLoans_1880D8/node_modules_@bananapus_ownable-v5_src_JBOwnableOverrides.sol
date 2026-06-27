// SPDX-License-Identifier: MIT
// Juicebox variation on OpenZeppelin Ownable
pragma solidity ^0.8.23;

import {JBPermissioned} from "@bananapus/core-v5/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v5/src/interfaces/IJBProjects.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {IJBOwnable} from "./interfaces/IJBOwnable.sol";
import {JBOwner} from "./structs/JBOwner.sol";

/// @notice An abstract base for `JBOwnable`, which restricts functions so they can only be called by a Juicebox
/// project's owner or a specific owner address. The owner can give access permission to other addresses with
/// `JBPermissions`.
abstract contract JBOwnableOverrides is Context, JBPermissioned, IJBOwnable {
    //*********************************************************************//
    // --------------------------- custom errors --------------------------//
    //*********************************************************************//b

    error JBOwnableOverrides_InvalidNewOwner();

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice This contract's owner information.
    JBOwner public override jbOwner;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @dev To restrict access to a Juicebox project's owner, pass that project's ID as the `initialProjectIdOwner` and
    /// the zero address as the `initialOwner`.
    /// To restrict access to a specific address, pass that address as the `initialOwner` and `0` as the
    /// `initialProjectIdOwner`.
    /// @dev The owner can give owner access to other addresses through the `permissions` contract.
    /// @param permissions A contract storing permissions.
    /// @param projects Mints ERC-721s that represent project ownership and transfers.
    /// @param initialOwner The owner if the `intialProjectIdOwner` is 0 (until ownership is transferred).
    /// @param initialProjectIdOwner The ID of the Juicebox project whose owner is this contract's owner (until
    /// ownership is transferred).
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        address initialOwner,
        uint88 initialProjectIdOwner
    )
        JBPermissioned(permissions)
    {
        PROJECTS = projects;

        // We force the inheriting contract to set an owner, as there is a low chance someone will use `JBOwnable` to
        // create an unowned contract.
        // It's more likely both were accidentally set to `0`. If you really want an unowned contract, set the owner to
        // an address and call `renounceOwnership()` in the constructor body.
        if (initialProjectIdOwner == 0 && initialOwner == address(0)) {
            revert JBOwnableOverrides_InvalidNewOwner();
        }

        _transferOwnership(initialOwner, initialProjectIdOwner);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Returns the owner's address based on this contract's `JBOwner`.
    function owner() public view virtual returns (address) {
        JBOwner memory ownerInfo = jbOwner;

        if (ownerInfo.projectId == 0) {
            return ownerInfo.owner;
        }

        return PROJECTS.ownerOf(ownerInfo.projectId);
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Reverts if the sender is not the owner.
    function _checkOwner() internal view virtual {
        JBOwner memory ownerInfo = jbOwner;

        _requirePermissionFrom({
            account: ownerInfo.projectId == 0 ? ownerInfo.owner : PROJECTS.ownerOf(ownerInfo.projectId),
            projectId: ownerInfo.projectId,
            permissionId: ownerInfo.permissionId
        });
    }

    //*********************************************************************//
    // ---------------------- public transactions ------------------------ //
    //*********************************************************************//

    /// @notice Gives up ownership of this contract, making it impossible to call `onlyOwner` and `_checkOwner`
    /// functions.
    /// @notice This can only be called by the current owner.
    function renounceOwnership() public virtual override {
        _checkOwner();
        _transferOwnership(address(0), 0);
    }

    /// @notice Sets the permission ID the owner can use to give other addresses owner access.
    /// @notice This can only be called by the current owner.
    /// @param permissionId The permission ID to use for `onlyOwner`.
    function setPermissionId(uint8 permissionId) public virtual override {
        _checkOwner();
        _setPermissionId(permissionId);
    }

    /// @notice Transfers ownership of this contract to a new address (the `newOwner`). Can only be called by the
    /// current owner.
    /// @notice This can only be called by the current owner.
    /// @param newOwner The address to transfer ownership to.
    function transferOwnership(address newOwner) public virtual override {
        _checkOwner();
        if (newOwner == address(0)) {
            revert JBOwnableOverrides_InvalidNewOwner();
        }

        _transferOwnership(newOwner, 0);
    }

    /// @notice Transfer ownership of this contract to a new Juicebox project.
    /// @notice This can only be called by the current owner.
    /// @dev The `projectId` must fit within a `uint88`.
    /// @param projectId The ID of the project to transfer ownership to.
    function transferOwnershipToProject(uint256 projectId) public virtual override {
        _checkOwner();
        if (projectId == 0 || projectId > type(uint88).max) {
            revert JBOwnableOverrides_InvalidNewOwner();
        }

        _transferOwnership(address(0), uint88(projectId));
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Either `newOwner` or `newProjectId` is non-zero or both are zero. But they can never both be non-zero.
    /// @dev This function exists because some contracts will try to deploy contracts for a project before
    function _emitTransferEvent(address previousOwner, address newOwner, uint88 newProjectId) internal virtual;

    /// @notice Sets the permission ID the owner can use to give other addresses owner access.
    /// @dev Internal function without access restriction.
    /// @param permissionId The permission ID to use for `onlyOwner`.
    function _setPermissionId(uint8 permissionId) internal virtual {
        jbOwner.permissionId = permissionId;
        emit PermissionIdChanged({newId: permissionId, caller: msg.sender});
    }

    /// @notice Helper to allow for drop-in replacement of OpenZeppelin `Ownable`.
    /// @param newOwner The address that should receive ownership of this contract.
    function _transferOwnership(address newOwner) internal virtual {
        _transferOwnership(newOwner, 0);
    }

    /// @notice Transfers this contract's ownership to an address (`newOwner`) OR a Juicebox project (`projectId`).
    /// @dev Updates this contract's `JBOwner` owner information and resets the `JBOwner.permissionId`.
    /// @dev If both `newOwner` and `projectId` are set, this will revert.
    /// @dev Internal function without access restriction.
    /// @param newOwner The address that should become this contract's owner.
    /// @param projectId The ID of the project whose owner should become this contract's owner.
    function _transferOwnership(address newOwner, uint88 projectId) internal virtual {
        // Can't set both a new owner and a new project ID.
        if (projectId != 0 && newOwner != address(0)) {
            revert JBOwnableOverrides_InvalidNewOwner();
        }
        // Load the owner information from storage.
        JBOwner memory ownerInfo = jbOwner;
        // Get the address of the old owner.
        address oldOwner = ownerInfo.projectId == 0 ? ownerInfo.owner : PROJECTS.ownerOf(ownerInfo.projectId);
        // Update the stored owner information to the new owner and reset the `permissionId`.
        // This is to prevent permissions clashes for the new user/owner.
        jbOwner = JBOwner({owner: newOwner, projectId: projectId, permissionId: 0});
        // Emit a transfer event with the new owner's address.
        _emitTransferEvent(oldOwner, newOwner, projectId);
    }
}
