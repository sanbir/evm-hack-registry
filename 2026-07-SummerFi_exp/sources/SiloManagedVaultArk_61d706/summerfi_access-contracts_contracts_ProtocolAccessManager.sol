// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ContractSpecificRoles, IProtocolAccessManager} from "../interfaces/IProtocolAccessManager.sol";
import {LimitedAccessControl} from "./LimitedAccessControl.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ProtocolAccessManager
 * @notice This contract is the central authority for access control within the protocol.
 * It defines and manages various roles that govern different aspects of the system.
 *
 * @dev This contract extends LimitedAccessControl, which restricts direct role management.
 * Roles are typically assigned during deployment or through governance proposals.
 *
 * The contract defines four main roles:
 * 1. GOVERNOR_ROLE: System-wide administrators
 * 2. KEEPER_ROLE: Routine maintenance operators
 * 3. SUPER_KEEPER_ROLE: Advanced maintenance operators
 * 4. COMMANDER_ROLE: Managers of specific protocol components (Arks)
 * 5. ADMIRALS_QUARTERS_ROLE: Specific role for admirals quarters bundler contract
 * Role Hierarchy and Management:
 * - The GOVERNOR_ROLE is at the top of the hierarchy and can manage all other roles.
 * - Other roles cannot manage roles directly due to LimitedAccessControl restrictions.
 * - Role assignments are typically done through governance proposals or during initial setup.
 *
 * Usage in the System:
 * - Other contracts in the system inherit from ProtocolAccessManaged, which checks permissions
 *   against this ProtocolAccessManager.
 * - Critical functions in various contracts are protected by role-based modifiers
 *   (e.g., onlyGovernor, onlyKeeper, etc.) which query this contract for permissions.
 *
 * Security Considerations:
 * - The GOVERNOR_ROLE has significant power and should be managed carefully, potentially
 *   through a multi-sig wallet or governance contract.
 * - The SUPER_KEEPER_ROLE has elevated privileges and should be assigned judiciously.
 * - The COMMANDER_ROLE is not directly manageable through this contract but is used
 *   in other parts of the system for specific access control.
 */
contract ProtocolAccessManager is IProtocolAccessManager, LimitedAccessControl {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role identifier for protocol governors - highest privilege level with admin capabilities
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Role identifier for super keepers who can globally perform fleet maintanence roles
    bytes32 public constant SUPER_KEEPER_ROLE = keccak256("SUPER_KEEPER_ROLE");

    /**
     * @notice Role identifier for protocol guardians
     * @dev Guardians have emergency powers across multiple protocol components:
     * - Can pause/unpause Fleet operations for security
     * - Can pause/unpause TipJar operations
     * - Can cancel governance proposals on SummerGovernor even if they don't meet normal cancellation requirements
     * - Can cancel TipJar proposals
     *
     * The guardian role serves as an emergency backstop to protect the protocol, but with less
     * privilege than governors.
     */
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /**
     * @notice Role identifier for decay controller
     * @dev This role allows the decay controller to manage the decay of user voting power
     */
    bytes32 public constant DECAY_CONTROLLER_ROLE =
        keccak256("DECAY_CONTROLLER_ROLE");

    /**
     * @notice Role identifier for admirals quarters bundler contract
     * @dev This role allows Admirals Quarters to unstake and withdraw assets from fleets, on behalf of users
     * @dev Withdrawn tokens go straight to users wallet, lowering the risk of manipulation if the role is compromised
     */
    bytes32 public constant ADMIRALS_QUARTERS_ROLE =
        keccak256("ADMIRALS_QUARTERS_ROLE");

    /// @notice Minimum allowed guardian expiration period (7 days)
    uint256 public constant MIN_GUARDIAN_EXPIRY = 7 days;

    /// @notice Maximum allowed guardian expiration period (180 days)
    uint256 public constant MAX_GUARDIAN_EXPIRY = 180 days;

    /// @notice Role identifier for the Foundation which manages vesting wallets and related operations
    bytes32 public constant FOUNDATION_ROLE = keccak256("FOUNDATION_ROLE");

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the ProtocolAccessManager contract
     * @param governor Address of the initial governor
     * @dev Grants the governor address the GOVERNOR_ROLE
     */
    constructor(address governor) {
        _grantRole(GOVERNOR_ROLE, governor);
    }

    /**
     * @dev Modifier to check that the caller has the Governor role
     */
    modifier onlyGovernor() {
        if (!hasRole(GOVERNOR_ROLE, msg.sender)) {
            revert CallerIsNotGovernor(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the contract supports a given interface
     * @dev Overrides the supportsInterface function from AccessControl
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return bool True if the contract supports the interface, false otherwise
     *
     * This function supports:
     * - IProtocolAccessManager interface
     * - All interfaces supported by the parent AccessControl contract
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IProtocolAccessManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IProtocolAccessManager
    function grantGovernorRole(address account) external onlyGovernor {
        _grantRole(GOVERNOR_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeGovernorRole(address account) external onlyGovernor {
        _revokeRole(GOVERNOR_ROLE, account);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL GOVERNOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolAccessManager
    function grantSuperKeeperRole(address account) external onlyGovernor {
        _grantRole(SUPER_KEEPER_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function grantGuardianRole(address account) external onlyGovernor {
        _grantRole(GUARDIAN_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeGuardianRole(address account) external onlyGovernor {
        _revokeRole(GUARDIAN_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeSuperKeeperRole(address account) external onlyGovernor {
        _revokeRole(SUPER_KEEPER_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function grantContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract,
        address roleOwner
    ) public onlyGovernor {
        bytes32 role = generateRole(roleName, roleTargetContract);
        _grantRole(role, roleOwner);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract,
        address roleOwner
    ) public onlyGovernor {
        bytes32 role = generateRole(roleName, roleTargetContract);
        _revokeRole(role, roleOwner);
    }

    /// @inheritdoc IProtocolAccessManager
    function grantCuratorRole(
        address fleetCommanderAddress,
        address account
    ) public onlyGovernor {
        grantContractSpecificRole(
            ContractSpecificRoles.CURATOR_ROLE,
            fleetCommanderAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeCuratorRole(
        address fleetCommanderAddress,
        address account
    ) public onlyGovernor {
        revokeContractSpecificRole(
            ContractSpecificRoles.CURATOR_ROLE,
            fleetCommanderAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function grantKeeperRole(
        address fleetCommanderAddress,
        address account
    ) public onlyGovernor {
        grantContractSpecificRole(
            ContractSpecificRoles.KEEPER_ROLE,
            fleetCommanderAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeKeeperRole(
        address fleetCommanderAddress,
        address account
    ) public onlyGovernor {
        revokeContractSpecificRole(
            ContractSpecificRoles.KEEPER_ROLE,
            fleetCommanderAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function grantCommanderRole(
        address arkAddress,
        address account
    ) public onlyGovernor {
        grantContractSpecificRole(
            ContractSpecificRoles.COMMANDER_ROLE,
            arkAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeCommanderRole(
        address arkAddress,
        address account
    ) public onlyGovernor {
        revokeContractSpecificRole(
            ContractSpecificRoles.COMMANDER_ROLE,
            arkAddress,
            account
        );
    }

    /// @inheritdoc IProtocolAccessManager
    function grantDecayControllerRole(address account) public onlyGovernor {
        _grantRole(DECAY_CONTROLLER_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeDecayControllerRole(address account) public onlyGovernor {
        _revokeRole(DECAY_CONTROLLER_ROLE, account);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolAccessManager
    function selfRevokeContractSpecificRole(
        ContractSpecificRoles roleName,
        address roleTargetContract
    ) public {
        bytes32 role = generateRole(roleName, roleTargetContract);
        if (!hasRole(role, msg.sender)) {
            revert CallerIsNotContractSpecificRole(msg.sender, role);
        }
        _revokeRole(role, msg.sender);
    }

    /// @inheritdoc IProtocolAccessManager
    function generateRole(
        ContractSpecificRoles roleName,
        address roleTargetContract
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(roleName, roleTargetContract));
    }

    /// @inheritdoc IProtocolAccessManager
    function grantAdmiralsQuartersRole(
        address account
    ) external onlyRole(GOVERNOR_ROLE) {
        _grantRole(ADMIRALS_QUARTERS_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeAdmiralsQuartersRole(
        address account
    ) external onlyRole(GOVERNOR_ROLE) {
        _revokeRole(ADMIRALS_QUARTERS_ROLE, account);
    }

    mapping(address guardian => uint256 expirationTimestamp)
        public guardianExpirations;

    /**
     * @notice Checks if an account is an active guardian (has role and not expired)
     * @param account Address to check
     * @return bool True if account is an active guardian
     */
    function isActiveGuardian(address account) public view returns (bool) {
        return
            hasRole(GUARDIAN_ROLE, account) &&
            guardianExpirations[account] > block.timestamp;
    }

    /**
     * @notice Sets the expiration timestamp for a guardian
     * @param account Guardian address
     * @param expiration Timestamp when guardian powers expire
     * @dev The expiration period (time from now until expiration) must be between MIN_GUARDIAN_EXPIRY and MAX_GUARDIAN_EXPIRY
     * This ensures guardians can't be immediately removed (protecting against malicious proposals) while still
     * allowing for their eventual phase-out (protecting against malicious guardians)
     */
    function setGuardianExpiration(
        address account,
        uint256 expiration
    ) external onlyRole(GOVERNOR_ROLE) {
        if (!hasRole(GUARDIAN_ROLE, account)) {
            revert CallerIsNotGuardian(account);
        }

        uint256 expiryPeriod = expiration - block.timestamp;
        if (
            expiryPeriod < MIN_GUARDIAN_EXPIRY ||
            expiryPeriod > MAX_GUARDIAN_EXPIRY
        ) {
            revert InvalidGuardianExpiryPeriod(
                expiryPeriod,
                MIN_GUARDIAN_EXPIRY,
                MAX_GUARDIAN_EXPIRY
            );
        }

        guardianExpirations[account] = expiration;
        emit GuardianExpirationSet(account, expiration);
    }

    /**
     * @inheritdoc IProtocolAccessManager
     */
    function hasRole(
        bytes32 role,
        address account
    )
        public
        view
        virtual
        override(IProtocolAccessManager, AccessControl)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function getGuardianExpiration(
        address account
    ) external view returns (uint256 expiration) {
        if (!hasRole(GUARDIAN_ROLE, account)) {
            revert CallerIsNotGuardian(account);
        }
        return guardianExpirations[account];
    }

    /// @inheritdoc IProtocolAccessManager
    function grantFoundationRole(address account) external onlyGovernor {
        _grantRole(FOUNDATION_ROLE, account);
    }

    /// @inheritdoc IProtocolAccessManager
    function revokeFoundationRole(address account) external onlyGovernor {
        _revokeRole(FOUNDATION_ROLE, account);
    }
}
