// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @dev Dynamic roles are roles that are not hardcoded in the contract but are defined by the protocol
 * Members of this enum are treated as prefixes to the role generated using prefix and target contract address
 * e.g generateRole(ContractSpecificRoles.CURATOR_ROLE, address(this)) for FleetCommander, to generate the CURATOR_ROLE
 * for the curator of the FleetCommander contract
 */
enum ContractSpecificRoles {
    CURATOR_ROLE,
    KEEPER_ROLE,
    COMMANDER_ROLE
}

/**
 * @title IProtocolAccessManager
 * @notice Defines system roles and provides role based remote-access control for
 *         contracts that inherit from ProtocolAccessManaged contract
 */
interface IProtocolAccessManager {
    /**
     * @notice Grants the Governor role to a given account
     *
     * @param account The account to which the Governor role will be granted
     */
    function grantGovernorRole(address account) external;

    /**
     * @notice Revokes the Governor role from a given account
     *
     * @param account The account from which the Governor role will be revoked
     */
    function revokeGovernorRole(address account) external;

    /**
     * @notice Grants the Super Keeper role to a given account
     *
     * @param account The account to which the Super Keeper role will be granted
     */
    function grantSuperKeeperRole(address account) external;

    /**
     * @notice Revokes the Super Keeper role from a given account
     *
     * @param account The account from which the Super Keeper role will be revoked
     */
    function revokeSuperKeeperRole(address account) external;

    /**
     * @dev Generates a unique role identifier based on the role name and target contract address
     * @param roleName The name of the role (from ContractSpecificRoles enum)
     * @param roleTargetContract The address of the contract the role is for
     * @return bytes32 The generated role identifier
     * @custom:internal-logic
     * - Combines the roleName and roleTargetContract using abi.encodePacked
     * - Applies keccak256 hash function to generate a unique bytes32 identifier
     * @custom:effects
     * - Does not modify any state, pure function
     * @custom:security-considerations
     * - Ensures unique role identifiers for different contracts
     * - Relies on the uniqueness of contract addresses and role names
     */
    function generateRole(
        ContractSpecificRoles roleName,
        address roleTargetContract
    ) external pure returns (bytes32);

    /**
     * @notice Grants a contract specific role to a given account
     * @param roleName The name of the role to grant
     * @param roleTargetContract The address of the contract to grant the role for
     * @param account The account to which the role will be granted
     */
    function grantContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract,
        address account
    ) external;

    /**
     * @notice Revokes a contract specific role from a given account
     * @param roleName The name of the role to revoke
     * @param roleTargetContract The address of the contract to revoke the role for
     * @param account The account from which the role will be revoked
     */
    function revokeContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract,
        address account
    ) external;

    /**
     * @notice Grants the Curator role to a given account
     * @param fleetCommanderAddress The address of the fleet commander to grant the role for
     * @param account The account to which the role will be granted
     */
    function grantCuratorRole(
        address fleetCommanderAddress,
        address account
    ) external;

    /**
     * @notice Revokes the Curator role from a given account
     * @param fleetCommanderAddress The address of the fleet commander to revoke the role for
     * @param account The account from which the role will be revoked
     */
    function revokeCuratorRole(
        address fleetCommanderAddress,
        address account
    ) external;

    /**
     * @notice Grants the Keeper role to a given account
     * @param fleetCommanderAddress The address of the fleet commander to grant the role for
     * @param account The account to which the role will be granted
     */
    function grantKeeperRole(
        address fleetCommanderAddress,
        address account
    ) external;

    /**
     * @notice Revokes the Keeper role from a given account
     * @param fleetCommanderAddress The address of the fleet commander to revoke the role for
     * @param account The account from which the role will be revoked
     */
    function revokeKeeperRole(
        address fleetCommanderAddress,
        address account
    ) external;

    /**
     * @notice Grants the Commander role for a specific Ark
     * @param arkAddress Address of the Ark contract
     * @param account Address to grant the Commander role to
     */
    function grantCommanderRole(address arkAddress, address account) external;

    /**
     * @notice Revokes the Commander role for a specific Ark
     * @param arkAddress Address of the Ark contract
     * @param account Address to revoke the Commander role from
     */
    function revokeCommanderRole(address arkAddress, address account) external;

    /**
     * @notice Revokes a contract specific role from the caller
     * @param roleName The name of the role to revoke
     * @param roleTargetContract The address of the contract to revoke the role for
     */
    function selfRevokeContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract
    ) external;

    /**
     * @notice Grants the Guardian role to a given account
     *
     * @param account The account to which the Guardian role will be granted
     */
    function grantGuardianRole(address account) external;

    /**
     * @notice Revokes the Guardian role from a given account
     *
     * @param account The account from which the Guardian role will be revoked
     */
    function revokeGuardianRole(address account) external;

    /**
     * @notice Grants the Decay Controller role to a given account
     * @param account The account to which the Decay Controller role will be granted
     */
    function grantDecayControllerRole(address account) external;

    /**
     * @notice Revokes the Decay Controller role from a given account
     * @param account The account from which the Decay Controller role will be revoked
     */
    function revokeDecayControllerRole(address account) external;

    /**
     * @notice Grants the ADMIRALS_QUARTERS_ROLE to an address
     * @param account The address to grant the role to
     */
    function grantAdmiralsQuartersRole(address account) external;

    /**
     * @notice Revokes the ADMIRALS_QUARTERS_ROLE from an address
     * @param account The address to revoke the role from
     */
    function revokeAdmiralsQuartersRole(address account) external;

    /*//////////////////////////////////////////////////////////////
                            ROLE CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for the Governor role
    function GOVERNOR_ROLE() external pure returns (bytes32);

    /// @notice Role identifier for the Guardian role
    function GUARDIAN_ROLE() external pure returns (bytes32);

    /// @notice Role identifier for the Super Keeper role
    function SUPER_KEEPER_ROLE() external pure returns (bytes32);

    /// @notice Role identifier for the Decay Controller role
    function DECAY_CONTROLLER_ROLE() external pure returns (bytes32);

    /// @notice Role identifier for the Admirals Quarters role
    function ADMIRALS_QUARTERS_ROLE() external pure returns (bytes32);

    /// @notice Role identifier for the Foundation, responsible for managing vesting wallets and related operations
    function FOUNDATION_ROLE() external pure returns (bytes32);

    /**
     * @notice Checks if an account has a specific role
     * @param role The role identifier to check
     * @param account The account to check the role for
     * @return bool True if the account has the role, false otherwise
     */
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a guardian's expiration is set
     * @param account The address of the guardian
     * @param expiration The timestamp until which the guardian powers are valid
     */
    event GuardianExpirationSet(address indexed account, uint256 expiration);

    /*//////////////////////////////////////////////////////////////
                            GUARDIAN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if an account is an active guardian (has role and not expired)
     * @param account Address to check
     * @return bool True if account is an active guardian
     */
    function isActiveGuardian(address account) external view returns (bool);

    /**
     * @notice Sets the expiration timestamp for a guardian
     * @param account Guardian address
     * @param expiration Timestamp when guardian powers expire
     */
    function setGuardianExpiration(
        address account,
        uint256 expiration
    ) external;

    /**
     * @notice Gets the expiration timestamp for a guardian
     * @param account Guardian address
     * @return uint256 Timestamp when guardian powers expire
     */
    function guardianExpirations(
        address account
    ) external view returns (uint256);

    /**
     * @notice Gets the expiration timestamp for a guardian
     * @param account Guardian address
     * @return expiration Timestamp when guardian powers expire
     */
    function getGuardianExpiration(
        address account
    ) external view returns (uint256 expiration);

    /**
     * @notice Emitted when an invalid guardian expiry period is set
     * @param expiryPeriod The expiry period that was set
     * @param minExpiryPeriod The minimum allowed expiry period
     * @param maxExpiryPeriod The maximum allowed expiry period
     */
    error InvalidGuardianExpiryPeriod(
        uint256 expiryPeriod,
        uint256 minExpiryPeriod,
        uint256 maxExpiryPeriod
    );

    /**
     * @notice Grants the Foundation role to a given account. The Foundation is responsible for
     * managing vesting wallets and related operations.
     * @param account The account to which the Foundation role will be granted
     */
    function grantFoundationRole(address account) external;

    /**
     * @notice Revokes the Foundation role from a given account
     * @param account The account from which the Foundation role will be revoked
     */
    function revokeFoundationRole(address account) external;
}
