// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Role identifiers — used by Vault4626 / StrategyUniswapV3 / PerformanceFeeTreasuryV3
// File-level constants so they can be imported directly by consumers.
// ─────────────────────────────────────────────────────────────────────────────
bytes32 constant DEFAULT_ADMIN_ROLE = 0x00; // OZ standard, also self-administered
bytes32 constant UPGRADER_ROLE      = keccak256("UPGRADER_ROLE");
bytes32 constant KEEPER_ROLE        = keccak256("KEEPER_ROLE");
bytes32 constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
bytes32 constant FEE_MANAGER_ROLE   = keccak256("FEE_MANAGER_ROLE");
bytes32 constant RESCUE_ROLE        = keccak256("RESCUE_ROLE");

/// @title  IRoleHub — minimal interface used by consuming proxies
/// @notice Vault4626 / Strategy / Treasury query this single function to gate
///         their role-protected operations.
interface IRoleHub {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title  RoleHub — centralized AccessControl proxy for autoswap / autoLP
/// @notice Hosts all AccessControlEnumerable state for one deployment domain.
///         Vault / Strategy / Treasury proxies hold a `roleHub` reference and
///         query `hasRole(...)` for every role-gated operation.
///
///         Why a separate proxy:
///         - Each consuming contract (Vault4626 = 24131 bytes) is at the
///           EIP-170 ceiling. AccessControl's storage + enumeration logic
///           cannot fit inside.
///         - Hub-and-Spoke isolates ALL role state into one auditable contract.
///           Future role additions / role hierarchy / timelocks etc. live here.
///
///         Trust model:
///         - autoswap: 1 RoleHub on Base, 1 on Arbitrum; all 13 vaults +
///           Treasury share each chain's hub. Same admin EOA holds all roles.
///         - autoLP fork: a separate RoleHub is deployed, with the client admin
///           and the provider upgrader held by distinct parties.
contract RoleHub is UUPSUpgradeable, IRoleHub {
    // ── Storage ──────────────────────────────────────────────────────────────
    /// @notice Hub-internal admin (separate from any role state). Used to
    ///         authorize UUPS upgrades on the Hub itself. NOT to be confused
    ///         with DEFAULT_ADMIN_ROLE which gates grantRole on consumer
    ///         contracts.
    /// @dev    Only the Hub admin can replace the Hub implementation. By
    ///         default this is the deployer; can be transferred via
    ///         setHubAdmin(). This is intentionally distinct from
    ///         DEFAULT_ADMIN_ROLE so a compromised Vault admin cannot push a
    ///         malicious Hub upgrade that grants themselves UPGRADER_ROLE on
    ///         all vaults.
    address public hubAdmin;

    /// @notice Initialization guard
    bool private _initialized;

    /// @notice role => account => holds-role bit
    mapping(bytes32 role => mapping(address account => bool)) private _hasRoleBit;

    /// @notice role => array of role holders (Enumerable)
    /// @dev    O(1) add/remove/contains via 1-based index map. Ordering
    ///         non-deterministic (swap-and-pop on remove).
    struct AddressSet {
        address[] _values;
        mapping(address => uint256) _indices; // 1-based, 0 = absent
    }
    mapping(bytes32 role => AddressSet) private _members;

    /// @notice Pending hubAdmin (2-step transfer pattern, OZ Ownable2Step style).
    /// @dev    setHubAdmin(addr) sets pendingHubAdmin = addr; the recipient
    ///         must then call acceptHubAdmin() to take ownership. Prevents
    ///         permanent brick from a single typo'd transfer transaction.
    address public pendingHubAdmin;

    // Reserved storage for future upgrades (decremented by 1 from 48 → 47 for pendingHubAdmin)
    uint256[47] private __gap;

    // ── Events (mirror IAccessControl for tooling compat) ────────────────────
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event HubAdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event HubAdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event HubAdminTransferCancelled(address indexed cancelledPendingAdmin);
    event Initialized(address indexed hubAdmin);

    // ── Errors ───────────────────────────────────────────────────────────────
    error AccessControlUnauthorizedAccount(address account, bytes32 role);
    error AccessControlBadConfirmation();
    error AlreadyInitialized();
    error ZeroAddress();
    error NotHubAdmin();
    error NotPendingHubAdmin();
    error LengthMismatch();

    // ── Modifier ─────────────────────────────────────────────────────────────
    modifier onlyHubAdmin() {
        if (msg.sender != hubAdmin) revert NotHubAdmin();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!_hasRoleBit[role][msg.sender]) {
            revert AccessControlUnauthorizedAccount(msg.sender, role);
        }
        _;
    }

    // ── Constructor / Initialize ─────────────────────────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {}

    /// @notice One-time initialize (called via proxy).
    /// @dev    Grants DEFAULT_ADMIN_ROLE to `defaultAdmin` (the operational
    ///         admin who can grantRole/revokeRole). Sets `hubAdmin` to
    ///         `deployer` (the entity controlling Hub upgrades). For autoswap
    ///         these are typically the same EOA; for whitelabel they differ
    ///         (provider = hubAdmin, client = defaultAdmin).
    function initialize(address deployer, address defaultAdmin) external {
        if (_initialized) revert AlreadyInitialized();
        if (deployer == address(0) || defaultAdmin == address(0)) revert ZeroAddress();
        _initialized = true;
        hubAdmin = deployer;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        emit Initialized(deployer);
        emit HubAdminTransferred(address(0), deployer);
    }

    /// @notice UUPS authorization — only hubAdmin can upgrade the Hub itself.
    function _authorizeUpgrade(address) internal view override onlyHubAdmin {}

    /// @notice Initiate a 2-step transfer of Hub-upgrade authority.
    /// @dev    Step 1: current hubAdmin nominates a candidate. Step 2: candidate
    ///         calls acceptHubAdmin() to take ownership. This prevents permanent
    ///         brick from a typo'd `setHubAdmin(0xWrong)` call. Used during
    ///         whitelabel handover (provider → client) or cold-wallet rotation.
    /// @param  newHubAdmin Candidate address (will not become hubAdmin until
    ///                     acceptHubAdmin() is called).
    function setHubAdmin(address newHubAdmin) external onlyHubAdmin {
        if (newHubAdmin == address(0)) revert ZeroAddress();
        pendingHubAdmin = newHubAdmin;
        emit HubAdminTransferStarted(hubAdmin, newHubAdmin);
    }

    /// @notice Step 2 of hubAdmin transfer: nominee accepts authority.
    /// @dev    Must be called by the address set as `pendingHubAdmin` via setHubAdmin().
    ///         Atomic: clears pendingHubAdmin and updates hubAdmin in the same call.
    function acceptHubAdmin() external {
        if (msg.sender != pendingHubAdmin) revert NotPendingHubAdmin();
        address oldAdmin = hubAdmin;
        hubAdmin = msg.sender;
        delete pendingHubAdmin;
        emit HubAdminTransferred(oldAdmin, msg.sender);
    }

    /// @notice Cancel a pending hubAdmin transfer. Callable by current hubAdmin only.
    function cancelHubAdminTransfer() external onlyHubAdmin {
        address pending = pendingHubAdmin;
        delete pendingHubAdmin;
        emit HubAdminTransferCancelled(pending);
    }

    // ── External views ───────────────────────────────────────────────────────

    /// @inheritdoc IRoleHub
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _hasRoleBit[role][account];
    }

    function getRoleMember(bytes32 role, uint256 index) external view returns (address) {
        return _members[role]._values[index];
    }

    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        return _members[role]._values.length;
    }

    function getRoleMembers(bytes32 role) external view returns (address[] memory) {
        return _members[role]._values;
    }

    // ── Role mutations ───────────────────────────────────────────────────────
    /// @notice Grant a role. Caller must hold DEFAULT_ADMIN_ROLE.
    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    /// @notice Revoke a role. Caller must hold DEFAULT_ADMIN_ROLE.
    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @notice Renounce a role for the caller. callerConfirmation must equal
    ///         msg.sender (OZ v5 convention) to prevent UI mistakes.
    function renounceRole(bytes32 role, address callerConfirmation) external {
        if (callerConfirmation != msg.sender) revert AccessControlBadConfirmation();
        _revokeRole(role, msg.sender);
    }

    // ── Batch helpers (gas-efficient, used by migration script) ─────────────

    /// @notice Initial role wiring for a fresh deployment domain. Caller must
    ///         hold DEFAULT_ADMIN_ROLE. Typically called once after Hub
    ///         deployment by the migration script.
    function bulkGrant(
        bytes32[] calldata roles,
        address[] calldata accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (roles.length != accounts.length) revert LengthMismatch();
        for (uint256 i = 0; i < roles.length; i++) {
            // Reject zero-address grant — silent role on address(0) inflates
            // member enumeration and confuses off-chain tooling. Caller error.
            if (accounts[i] == address(0)) revert ZeroAddress();
            _grantRole(roles[i], accounts[i]);
        }
    }

    // ── Internals ────────────────────────────────────────────────────────────
    function _grantRole(bytes32 role, address account) internal returns (bool) {
        if (_hasRoleBit[role][account]) return false;
        _hasRoleBit[role][account] = true;
        AddressSet storage set = _members[role];
        if (set._indices[account] == 0) {
            set._values.push(account);
            set._indices[account] = set._values.length;
        }
        emit RoleGranted(role, account, msg.sender);
        return true;
    }

    function _revokeRole(bytes32 role, address account) internal returns (bool) {
        if (!_hasRoleBit[role][account]) return false;
        _hasRoleBit[role][account] = false;
        AddressSet storage set = _members[role];
        uint256 idx = set._indices[account];
        if (idx != 0) {
            uint256 lastIdx = set._values.length;
            if (idx != lastIdx) {
                address last = set._values[lastIdx - 1];
                set._values[idx - 1] = last;
                set._indices[last] = idx;
            }
            set._values.pop();
            delete set._indices[account];
        }
        emit RoleRevoked(role, account, msg.sender);
        return true;
    }
}
