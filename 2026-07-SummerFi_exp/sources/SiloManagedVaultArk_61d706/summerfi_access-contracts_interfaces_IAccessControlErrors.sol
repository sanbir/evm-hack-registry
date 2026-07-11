// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IAccessControlErrors
 * @dev This file contains custom error definitions for access control in the system.
 * @notice These custom errors provide more gas-efficient and informative error handling
 * compared to traditional require statements with string messages.
 */
interface IAccessControlErrors {
    /**
     * @notice Thrown when a caller does not have the required role.
     */
    error CallerIsNotContractSpecificRole(address caller, bytes32 role);

    /**
     * @notice Thrown when a caller is not the curator.
     */
    error CallerIsNotCurator(address caller);

    /**
     * @notice Thrown when a caller is not the governor.
     */
    error CallerIsNotGovernor(address caller);

    /**
     * @notice Thrown when a caller is not a keeper.
     */
    error CallerIsNotKeeper(address caller);

    /**
     * @notice Thrown when a caller is not a super keeper.
     */
    error CallerIsNotSuperKeeper(address caller);

    /**
     * @notice Thrown when a caller is not the commander.
     */
    error CallerIsNotCommander(address caller);

    /**
     * @notice Thrown when a caller is neither the Raft nor the commander.
     */
    error CallerIsNotRaftOrCommander(address caller);

    /**
     * @notice Thrown when a caller is not the Raft.
     */
    error CallerIsNotRaft(address caller);

    /**
     * @notice Thrown when a caller is not an admin.
     */
    error CallerIsNotAdmin(address caller);

    /**
     * @notice Thrown when a caller is not the guardian.
     */
    error CallerIsNotGuardian(address caller);

    /**
     * @notice Thrown when a caller is not the guardian or governor.
     */
    error CallerIsNotGuardianOrGovernor(address caller);

    /**
     * @notice Thrown when a caller is not the decay controller.
     */
    error CallerIsNotDecayController(address caller);

    /**
     * @notice Thrown when a caller is not authorized to board.
     */
    error CallerIsNotAuthorizedToBoard(address caller);

    /**
     * @notice Thrown when direct grant is disabled.
     */
    error DirectGrantIsDisabled(address caller);

    /**
     * @notice Thrown when direct revoke is disabled.
     */
    error DirectRevokeIsDisabled(address caller);

    /**
     * @notice Thrown when an invalid access manager address is provided.
     */
    error InvalidAccessManagerAddress(address invalidAddress);

    /**
     * @notice Error thrown when a caller is not the Foundation
     * @param caller The address that attempted the operation
     */
    error CallerIsNotFoundation(address caller);
}
