// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArkAccessManaged} from "../interfaces/IArkAccessManaged.sol";

import {IConfigurationManaged} from "../interfaces/IConfigurationManaged.sol";
import {IFleetCommander} from "../interfaces/IFleetCommander.sol";
import {ContractSpecificRoles} from "@summerfi/access-contracts/interfaces/IProtocolAccessManager.sol";

import {ProtocolAccessManaged} from "@summerfi/access-contracts/contracts/ProtocolAccessManaged.sol";

/**
 * @title ArkAccessManaged
 * @author SummerFi
 * @notice This contract manages access control for Ark-related operations.
 * @dev Inherits from ProtocolAccessManaged and implements IArkAccessManaged.
 * @custom:see IArkAccessManaged
 */
contract ArkAccessManaged is IArkAccessManaged, ProtocolAccessManaged {
    /**
     * @notice Initializes the ArkAccessManaged contract.
     * @param accessManager The address of the access manager contract.
     */
    constructor(address accessManager) ProtocolAccessManaged(accessManager) {}

    /**
     * @notice Checks if the caller is authorized to board funds.
     * @dev This modifier allows the Commander, RAFT contract, or active Arks to proceed.
     * @param commander The address of the FleetCommander contract.
     * @custom:internal-logic
     * - Checks if the caller is the registered commander
     * - If not, checks if the caller is the RAFT contract
     * - If not, checks if the caller is an active Ark in the FleetCommander
     * @custom:effects
     * - Reverts if the caller doesn't have the necessary permissions
     * - Allows the function to proceed if the caller is authorized
     * @custom:security-considerations
     * - Ensures that only authorized entities can board funds
     * - Relies on the correct setup of the FleetCommander and RAFT contracts
     */
    modifier onlyAuthorizedToBoard(address commander) {
        if (commander != _msgSender()) {
            address msgSender = _msgSender();
            bool isRaft = msgSender ==
                IConfigurationManaged(address(this)).raft();

            if (!isRaft) {
                bool isArk = IFleetCommander(commander).isArkActiveOrBufferArk(
                    msgSender
                );
                if (!isArk) {
                    revert CallerIsNotAuthorizedToBoard(msgSender);
                }
            }
        }
        _;
    }

    /**
     * @notice Restricts access to only the RAFT contract.
     * @dev Modifier to check that the caller is the RAFT contract
     * @custom:internal-logic
     * - Retrieves the RAFT address from the ConfigurationManaged contract
     * - Compares the caller's address with the RAFT address
     * @custom:effects
     * - Reverts if the caller is not the RAFT contract
     * - Allows the function to proceed if the caller is the RAFT contract
     * @custom:security-considerations
     * - Ensures that only the RAFT contract can call certain functions
     * - Relies on the correct setup of the ConfigurationManaged contract
     */
    modifier onlyRaft() {
        if (_msgSender() != IConfigurationManaged(address(this)).raft()) {
            revert CallerIsNotRaft(_msgSender());
        }
        _;
    }

    /**
     * @notice Checks if the caller has the Commander role.
     * @dev Internal function to check if the caller has the Commander role
     * @return bool True if the caller has the Commander role, false otherwise
     * @custom:internal-logic
     * - Generates the Commander role identifier for this contract
     * - Checks if the caller has the generated role in the access manager
     * @custom:effects
     * - Does not modify any state, view function only
     * @custom:security-considerations
     * - Relies on the correct setup of the access manager
     * - Assumes that the Commander role is properly assigned
     */
    function _hasCommanderRole() internal view returns (bool) {
        return
            _accessManager.hasRole(
                generateRole(
                    ContractSpecificRoles.COMMANDER_ROLE,
                    address(this)
                ),
                _msgSender()
            );
    }
}
