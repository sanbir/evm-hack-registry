// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Owner information for a given instance of `JBOwnableOverrides`.
/// @custom:member owner If `projectId` is 0, this address has owner access.
/// @custom:member projectId The owner of the `JBProjects` ERC-721 with this ID has owner access. If this is 0, the
/// `owner` address has owner access.
/// @custom:member permissionId The permission ID which corresponds to owner access. See `JBPermissions` in `nana-core`
/// and `nana-permission-ids`.
struct JBOwner {
    address owner;
    uint88 projectId;
    uint8 permissionId;
}
