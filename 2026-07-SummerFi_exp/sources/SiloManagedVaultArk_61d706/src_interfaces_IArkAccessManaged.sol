// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IArkAccessManaged
 * @notice Extends the ProtocolAccessManaged contract with Ark specific AccessControl
 *         Used to specifically tie one FleetCommander to each Ark
 *
 * @dev One Ark specific role is defined:
 *   - Commander: is the fleet commander contract itself and couples an
 *        Ark to specific Fleet Commander
 *
 *   The Commander role is still declared on the access manager to centralise
 *   role definitions.
 */
interface IArkAccessManaged {}
