/*


███████╗    ██╗         ███████╗    ██╗   ██╗     █████╗     ████████╗    ███████╗            ███████╗    ██╗
██╔════╝    ██║         ██╔════╝    ██║   ██║    ██╔══██╗    ╚══██╔══╝    ██╔════╝            ██╔════╝    ██║
█████╗      ██║         █████╗      ██║   ██║    ███████║       ██║       █████╗              █████╗      ██║
██╔══╝      ██║         ██╔══╝      ╚██╗ ██╔╝    ██╔══██║       ██║       ██╔══╝              ██╔══╝      ██║
███████╗    ███████╗    ███████╗     ╚████╔╝     ██║  ██║       ██║       ███████╗            ██║         ██║
╚══════╝    ╚══════╝    ╚══════╝      ╚═══╝      ╚═╝  ╚═╝       ╚═╝       ╚══════╝            ╚═╝         ╚═╝
                                                                                                             

Website: ElevateFi.io
SPDX-License-Identifier: MIT
*/


pragma solidity 0.8.30;
// File: @openzeppelin/contracts/access/IAccessControl.sol
// OpenZeppelin Contracts (last updated v5.4.0) (access/IAccessControl.sol)
/**
 * @dev External interface of AccessControl declared to support ERC-165 detection.
 */
interface IAccessControl {
    /**
     * @dev The `account` is missing a role.
     */
    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);

    /**
     * @dev The caller of a function is not the expected one.
     *
     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.
     */
    error AccessControlBadConfirmation();

    /**
     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`
     *
     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite
     * {RoleAdminChanged} not being emitted to signal this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).
     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.
     */
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Emitted when `account` is revoked `role`.
     *
     * `sender` is the account that originated the contract call:
     *   - if using `revokeRole`, it is the admin role bearer
     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)
     */
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {AccessControl-_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been granted `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     */
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)


/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

// File: @openzeppelin/contracts/utils/introspection/IERC165.sol


// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/IERC165.sol)


/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// File: @openzeppelin/contracts/utils/introspection/ERC165.sol


// OpenZeppelin Contracts (last updated v5.4.0) (utils/introspection/ERC165.sol)



/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC-165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// File: @openzeppelin/contracts/access/AccessControl.sol


// OpenZeppelin Contracts (last updated v5.4.0) (access/AccessControl.sol)





/**
 * @dev Contract module that allows children to implement role-based access
 * control mechanisms. This is a lightweight version that doesn't allow enumerating role
 * members except through off-chain means by accessing the contract event logs. Some
 * applications may benefit from on-chain enumerability, for those cases see
 * {AccessControlEnumerable}.
 *
 * Roles are referred to by their `bytes32` identifier. These should be exposed
 * in the external API and be unique. The best way to achieve this is by
 * using `public constant` hash digests:
 *
 * ```solidity
 * bytes32 public constant MY_ROLE = keccak256("MY_ROLE");
 * ```
 *
 * Roles can be used to represent a set of permissions. To restrict access to a
 * function call, use {hasRole}:
 *
 * ```solidity
 * function foo() public {
 *     require(hasRole(MY_ROLE, msg.sender));
 *     ...
 * }
 * ```
 *
 * Roles can be granted and revoked dynamically via the {grantRole} and
 * {revokeRole} functions. Each role has an associated admin role, and only
 * accounts that have a role's admin role can call {grantRole} and {revokeRole}.
 *
 * By default, the admin role for all roles is `DEFAULT_ADMIN_ROLE`, which means
 * that only accounts with this role will be able to grant or revoke other
 * roles. More complex role relationships can be created by using
 * {_setRoleAdmin}.
 *
 * WARNING: The `DEFAULT_ADMIN_ROLE` is also its own admin: it has permission to
 * grant and revoke this role. Extra precautions should be taken to secure
 * accounts that have been granted it. We recommend using {AccessControlDefaultAdminRules}
 * to enforce additional security measures for this role.
 */
abstract contract AccessControl is Context, IAccessControl, ERC165 {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData) private _roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        return _roles[role].hasRole[account];
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `_msgSender()`
     * is missing `role`. Overriding this function changes the behavior of the {onlyRole} modifier.
     */
    function _checkRole(bytes32 role) internal view virtual {
        _checkRole(role, _msgSender());
    }

    /**
     * @dev Reverts with an {AccessControlUnauthorizedAccount} error if `account`
     * is missing `role`.
     */
    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) {
            revert AccessControlUnauthorizedAccount(account, role);
        }
    }

    /**
     * @dev Returns the admin role that controls `role`. See {grantRole} and
     * {revokeRole}.
     *
     * To change a role's admin, use {_setRoleAdmin}.
     */
    function getRoleAdmin(bytes32 role) public view virtual returns (bytes32) {
        return _roles[role].adminRole;
    }

    /**
     * @dev Grants `role` to `account`.
     *
     * If `account` had not been already granted `role`, emits a {RoleGranted}
     * event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleGranted} event.
     */
    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _grantRole(role, account);
    }

    /**
     * @dev Revokes `role` from `account`.
     *
     * If `account` had been granted `role`, emits a {RoleRevoked} event.
     *
     * Requirements:
     *
     * - the caller must have ``role``'s admin role.
     *
     * May emit a {RoleRevoked} event.
     */
    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    /**
     * @dev Revokes `role` from the calling account.
     *
     * Roles are often managed via {grantRole} and {revokeRole}: this function's
     * purpose is to provide a mechanism for accounts to lose their privileges
     * if they are compromised (such as when a trusted device is misplaced).
     *
     * If the calling account had been revoked `role`, emits a {RoleRevoked}
     * event.
     *
     * Requirements:
     *
     * - the caller must be `callerConfirmation`.
     *
     * May emit a {RoleRevoked} event.
     */
    function renounceRole(bytes32 role, address callerConfirmation) public virtual {
        if (callerConfirmation != _msgSender()) {
            revert AccessControlBadConfirmation();
        }

        _revokeRole(role, callerConfirmation);
    }

    /**
     * @dev Sets `adminRole` as ``role``'s admin role.
     *
     * Emits a {RoleAdminChanged} event.
     */
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    /**
     * @dev Attempts to grant `role` to `account` and returns a boolean indicating if `role` was granted.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleGranted} event.
     */
    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!hasRole(role, account)) {
            _roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` from `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (hasRole(role, account)) {
            _roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v5.4.0) (token/ERC20/IERC20.sol)


/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// File: @uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol


interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

// File: @uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol


interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountA, uint amountB);
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountToken, uint amountETH);
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        returns (uint[] memory amounts);
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        payable
        returns (uint[] memory amounts);

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

// File: @uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol



interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}





/// @title Oracle for DAO Rewards with Auto‐Catchup & Tier Tracking
/// @notice Ingests off-chain computed DAO rewards in batches, auto-accrues missed epochs,  
///         tracks user tiers, and allows the StakingVault to pull & reset claimable balances.
contract Oracle is AccessControl {
    bytes32 public constant DAO_MANAGER_ROLE  = keccak256("DAO_MANAGER_ROLE");
    bytes32 public constant STAKING_ROLE      = keccak256("STAKING_ROLE");

    /// @notice Last opened epoch for batch ingestion
    uint256 public currentEpoch;

    /// @dev Tracks ingestion status per epoch and per batch
    mapping(uint256 => bool)                        public batchStarted;
    mapping(uint256 => bool)                        public batchFinished;
    mapping(uint256 => mapping(uint256 => bool))    public batchDone;

    /// @notice Unclaimed DAO rewards per user (in EFI)
    mapping(address => uint256) public pendingDaoReward;

    /// @notice Total Team's active stake
    mapping(address => uint256) public activeTeamStake;
    
    /// @notice Last per‐epoch reward amount recorded for each user
    mapping(address => uint256) public userPerEpochReward;
    /// @notice Last epoch index for which each user's rewards were processed
    mapping(address => uint256) public lastProcessedEpoch;
    /// @notice Current DAO tier for each user (0=v1, 1=v2, …)
    mapping(address => uint8)   public userDaoTier;

    /// @notice Emitted when an epoch is opened for ingestion
    event BatchStarted(uint256 indexed epoch);
    /// @notice Emitted when a batch of rewards is ingested
    event BatchExecuted(uint256 indexed epoch, uint256 indexed batchId, uint256 count);
    /// @notice Emitted when an epoch is closed for ingestion
    event BatchFinished(uint256 indexed epoch);

    /// @notice Emitted when a user’s rewards are claimed via the staking contract
    event RewardsClaimed(address indexed user, uint8 tier, uint256 amount, uint256 epoch);

    /// @param admin           Address to receive DEFAULT_ADMIN_ROLE & DAO_MANAGER_ROLE
    /// @param stakingContract Address of the StakingVault (granted STAKING_ROLE)
    constructor(address admin, address stakingContract) {
        require(admin           != address(0), "Oracle: zero admin");
        require(stakingContract != address(0), "Oracle: zero staking");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DAO_MANAGER_ROLE,    admin);
        _grantRole(STAKING_ROLE,        stakingContract);
    }

    /// @notice Open a new epoch so that `executeBatch` may be called
    /// @param epoch The epoch number to start (must exceed previous)
    function startBatch(uint256 epoch) external onlyRole(DAO_MANAGER_ROLE) {
        require(epoch > currentEpoch, "Oracle: epoch too low");
        require(!batchFinished[epoch], "Oracle: epoch finished");
        currentEpoch = epoch;
        batchStarted[epoch] = true;
        emit BatchStarted(epoch);
    }

    /// @notice Ingest one precomputed batch of DAO rewards & tiers for the current epoch
    /// @param batchId Unique identifier for this batch within the epoch
    /// @param users   Array of user addresses
    /// @param rewards Array of EFI-denominated reward amounts
    /// @param tiers   Array of DAO tier indices for each user
    function executeBatch(
        uint256        batchId,
        address[] calldata users,
        uint256[] calldata rewards,
        uint256[] calldata activeTeamStaks,
        uint8[]   calldata tiers
    ) external onlyRole(DAO_MANAGER_ROLE) {
        uint256 epoch = currentEpoch;
        require(batchStarted[epoch], "Oracle: epoch not started");
        require(!batchFinished[epoch], "Oracle: epoch finished");
        require(!batchDone[epoch][batchId], "Oracle: batch done");

        uint256 n = users.length;
        require(n == rewards.length && n == tiers.length, "Oracle: length mismatch");

        for (uint256 i = 0; i < n; i++) {
            address u         = users[i];
            uint256 newReward = rewards[i];

            // 1) Auto-accrue missed epochs
            uint256 lastE = lastProcessedEpoch[u];
            if (lastE < epoch) {
                uint256 missed = epoch - lastE - 1;
                if (missed > 0) {
                    pendingDaoReward[u] += userPerEpochReward[u] * missed;
                }
            }

            // 2) Add this epoch’s reward
            pendingDaoReward[u] += newReward;

            // 3) Update per-epoch rate, tier & last processed epoch
            userPerEpochReward[u] = newReward;
            userDaoTier[u]        = tiers[i];
            activeTeamStake[u] = activeTeamStaks[i];
            lastProcessedEpoch[u] = epoch;
        }

        batchDone[epoch][batchId] = true;
        emit BatchExecuted(epoch, batchId, n);
    }

    /// @notice Close the current epoch to further ingestion
    /// @param epoch The epoch number to finish
    function finishBatch(uint256 epoch) external onlyRole(DAO_MANAGER_ROLE) {
        require(batchStarted[epoch], "Oracle: epoch not started");
        require(!batchFinished[epoch], "Oracle: already finished");
        batchFinished[epoch] = true;
        emit BatchFinished(epoch);
    }

    /// @notice View up-to-date claimable DAO rewards for a user as of a given epoch
    /// @param user  Address whose rewards to query
    /// @param epoch The current epoch number (from StakingVault)
    /// @return total = pendingDaoReward[user] + (epoch − lastProcessedEpoch[user]) × userPerEpochReward[user]
    function viewAvailableDaoRewards(address user, uint256 epoch) external view returns (uint256 total) {
        total = pendingDaoReward[user];
        uint256 lastE = lastProcessedEpoch[user];
        if (epoch > lastE) {
            uint256 missed = epoch - lastE;
            total += userPerEpochReward[user] * missed;
        }
    }

    /// @notice Clear a user’s accrued DAO rewards after your staking contract has minted them
    /// @param user  The account whose rewards are being claimed
    /// @param epoch The epoch number used to compute their rewards
    function claimDaoRewards(address user, uint256 epoch)
        external
        onlyRole(STAKING_ROLE)
    {
        uint256 amount = pendingDaoReward[user];
        pendingDaoReward[user] = 0;
        lastProcessedEpoch[user] = epoch;

        emit RewardsClaimed(user, userDaoTier[user], amount, epoch);
    }
}


// File: contracts/EFI/ElevateFi/Tree.sol
/// @title StakingTree referral registry
/// @author ElevateFi
/// @notice Simple on-chain mapping of users to their referrers (uplines) and direct downlines.
/// @dev This contract only records relationships; it does not transfer or hold funds.
///      A user may set their referrer exactly once. No validation is enforced that the
///      `upline` has registered—any address can be set as a referrer.
contract StakingTree {
    /// @notice The immediate referrer (upline) for each user; zero address means unset.
    mapping(address => address) public referrer;

    /// @notice Direct downlines recorded for each `upline` address.
    mapping(address => address[]) public directReferrals;

    /// @notice Emitted when a user registers their `upline`.
    /// @param user   The address that set a referrer.
    /// @param upline The address recorded as the user's referrer.
    event UserRegistration(address indexed user, address indexed upline);

    /// @notice Register your referrer (upline). Can only be set once.
    /// @dev Reverts if the caller already has a referrer, or if `upline` equals the caller.
    ///      This function does not enforce nonzero `upline`; using the zero address is allowed
    ///      only if your app flow intends to represent “no upline”.
    /// @param upline The address of your referrer.
    function registerReferrer(address upline) external {
        
        require(referrer[msg.sender] == address(0), "Referrer set");
        require(upline != msg.sender, "Cannot refer self");

        referrer[msg.sender] = upline;
        directReferrals[upline].push(msg.sender);

        emit UserRegistration(msg.sender, upline);
    }

    /// @notice Returns the referrer (upline) for a given `user`.
    /// @param user The account to query.
    /// @return The recorded upline address, or the zero address if none.
    function getReferrer(address user) external view returns (address) {
        return referrer[user];
    }

    /// @notice Returns the list of direct downlines for `user`.
    /// @param user The upline whose direct referrals will be returned.
    /// @return An array of addresses directly referred by `user` (may be empty).
    function getDirectDownlines(address user) external view returns (address[] memory) {
        return directReferrals[user];
    }

    /// @notice Returns the number of direct downlines for `user`.
    /// @param user The upline whose direct referral count will be returned.
    /// @return The length of the direct downlines array.
    function getDirectDownlinesTotal(address user) external view returns (uint256) {
        return directReferrals[user].length;
    }
}


interface EFI is IERC20 {
    function burnFromStakingContract(address from, uint256 amount) external;
    function mint(address to, uint256 amount) external;
}

interface sEFI is IERC20 {
    function burnFromStakingContract(address from, uint256 amount) external;
    function mint(address to, uint256 amount) external;
    function rebase(uint256 supplyDelta) external  returns (uint256 newSupply);
}


/// File: contracts/EFI/ElevateFi/StakingVault.sol
/// @title ElevateFi StakingVault
/// @notice Unified on-demand + long-term staking with MLM & DAO rewards
contract Staking_Implementation is AccessControl {

    /* ======== CONSTANTS ======== */
    address public constant BURN_ADDRESS        = 0x000000000000000000000000000000000000dEaD;
    
    /* ======== VARIABLES ======== */
    bool public initialised;
    bool private _inSefiHook;  // soft reentrancy guard
    IUniswapV2Router02 public router;
    IUniswapV2Pair public pricePair;
    address public dai;
    address public treasury;
    sEFI           public sefi;
    EFI            public efi;
    StakingTree   public tree;
    uint256 public MLM_FEE_THRESHOLD   = 500_000;  // staker count threshold for MLM burn
    uint256 public EFI_SUPPLY_THRESHOLD_BURNING = 50_000_000 * 1e18;    // EFI supply threshold for MLM burn
    uint256 public EPOCH_LENGTH        = 43_200;   // ~24h in blocks
    uint256 public BASE_RATE           = 3333;     // 0.3333% per epoch (3333/1e6)
    uint256 public MIN_RATE            = 2333;     // 0.2333% floor
    uint256 public SLAB_SIZE           = 200_000;  // staker count per slab
    uint256 public MLM_FEE_PCT         = 25;       // 25% burn on MLM and DAO after certain threshold
    uint256 public DAI_LOCK_DELAY = 24 hours;
    struct DaiLock {
        uint256 daiAmount;     // amount of DAI locked
        uint256 lockTimestamp; // when it was locked
    }
    mapping(address => DaiLock[]) public daiLocks;      // Active DAI‐locks for each user
    mapping(address => uint256) public energyBalance;   // Energy credits pre‐purchased by burning EFI
    mapping(address => uint256) public unclaimedMLM;    // Accumulated but unclaimed gross MLM/DAO rewards per user
    mapping(address => uint256) public unclaimedDAO;    // Accumulated but unclaimed DAO rewards per user

    /* ======== EPOCH STATE ======== */
    uint256 public epochNumber;
    uint256 public epochEnd;

    /* ======== STAKING STATE ======== */
    mapping(address => uint256) public stakeBalance;   // on-demand EFI stakes
    uint256 public activeStakerCount;
    mapping(address => bool) private _hasStaked;

    /* ======== BOND (LONG TERM STAKING) STATE ======== */
    uint256 public totalLongTermPrincipal;
    uint256 public termBlocks = 360 days / 2;   // 12 months time in blocks in polygon
    uint256 public flatBonusPct = 7e16;         // 7% extra bonus
    struct LTStake {
        bool    active;
        uint256 valueEFI;           // principal in EFI‐units
        uint256 startBlock;         // deposit block
        uint256 endBlock;           // vesting expiration
        uint256 flatBonusPct;       // e.g. 4e16 == 4%
        uint256 lastCompoundEpoch;  // Epoch where user claimed compounding rewards.
    }
    mapping(address => LTStake[]) public bondStakes;

    /* ======== MLM STATE ======== */    
    mapping(address => uint256[15]) public levelStake;    // down-line stake per level
    mapping(address => uint256[15]) public lastLevelUpdateEpoch;    // Tracks the epoch at which the principal at a given level was last changed
    mapping(address => uint256) public qualifiedDirectReferralsCount; // counts active referrals with $100+ stake
    mapping(address => mapping(address => bool)) public isReferralQualified; // referrer => referral => bool
    mapping(address => uint256) public lastMLMEpoch;
    uint8 public noOfDownlinesForCache = 50;    // number of downlines to cache in the MLM tree
    uint8[15]   public overrideRates   = [10,8,7,5,5,5,5,4,4,4,4,4,4,4,4];
    uint8[15]   public reqDirects      = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15];
    uint256[15] public reqSelfStakeUSD = [
        100e18,300e18,500e18,1000e18,1500e18,
        2000e18,3000e18,4000e18,5000e18,6000e18,
        7000e18,8000e18,9000e18,10000e18,11000e18
    ];
    

    /* ======== DAO STATE ======== */
    Oracle public oracle;
    

    /* ======== EVENTS ======== */
    event Rebased(uint256 epochNumber, uint256 totalStaking, uint256 profit);
    event StakedEFI(address indexed user, uint256 amount);
    event UnstakedEFI(address indexed user, uint256 amount);
    event StakedBond(address indexed user, uint256 amount);
    event RedeemedBond(address indexed user, uint256 idx, uint256 compoundInterest, uint256 principal, uint256 flatBonus);
    event ClaimedMLM(address indexed user, uint256 netReward);
    event DAOClaim(address indexed user, uint8 tierPct, uint256 reward, uint256 epochs);
    event ClaimedBondCompoundingRewards(address indexed user, uint256 idx, uint256 interest);
    event DAOTiersSet();
    event DaiLockCreated(address indexed user, uint256 lockID, uint256 daiAmount, uint256 lockTimestamp);
    event DaiLockReleased(address indexed user, uint256 lockID, uint256 daiAmount, uint256 efiReturned);
    event SetContracts(address _EFI, address _sEFI, address _oracle, address _treasury);
    event SetPairData(address _pricePair, address _router, address _dai);
    event SetMlmFeeThreshold(uint256 _mlmFeeThreshold);
    event UserRegistration(address indexed user, address indexed upline);
    event EnergyPurchased(address indexed user, uint256 EFIamount, uint256 energy);
    
    

    mapping(address => bool) public walletFrozen;

    // Eligibility watermark: epoch when the user became eligible for a given level.
    // 0 means "currently ineligible".
    mapping(address => uint256[15]) public eligibilityOnSince;





    // ===== Variables additions (append-only) =====
    sEFI public sefiSilver;
    sEFI public sefiGold;

    bool public v2Initialized;

    // plan rates in ppm (1e6 = 100%)
    uint32 public silverRatePpm;     // 6000  = 0.60% daily
    uint32 public goldRatePpm;       // 8000  = 0.80% daily
    uint32 public platinumRatePpm;   // 10000 = 1.00% daily

    // MLM rate configurable
    uint32 public mlmRatePpm;

    // allowlist for hook callers
    mapping(address => bool) public isSefiToken;

    // lock type per bond entry: 1=silverLock, 2=goldLock, 3=platinumLock
    mapping(address => mapping(uint256 => uint8)) public bondType;

    // platinum principal used for qualification helper
    mapping(address => uint256) public platinumLockedPrincipal;

    // skip heavy hook work during vault mint/burn
    bool private _skipSefiHook;




    /* ============================================================
    * =============== V3: PACKAGE STAKING STORAGE ===============
    * ============================================================
    *
    *  EFI is locked directly into packages (no sEFI).
    *  Rewards accrue DAILY (by epoch), LINEAR (no compounding),
    *  and STOP at maturity (no extra rewards after endEpoch).
    *
    *  Epoch stays block-based to keep offchain dependencies stable.
    *  We still use the function name `rebase()` but it only advances epoch.
    *
    *  Polygon ~2s block time -> ~43,200 blocks/day.
    *  NOTE: blocktime is variable; epoch is an approximation as before.
    * ============================================================ */

    //uint256 public constant BLOCKS_PER_DAY = 43_200;

    /* ------------------------------------------------------------
    * Package IDs (UI should use these exact ids)
    *  0 => 45 days @ 0.40% per day (4000 ppm)
    *  1 => 90 days @ 0.60% per day (6000 ppm)
    *  2 => 180 days @ 0.80% per day (8000 ppm)
    *  3 => 365 days @ 1.00% per day (10000 ppm)
    * ------------------------------------------------------------ */
    uint16[4] public packageLockDays = [45, 90, 180, 365];
    uint32[4] public packageRatePpm  = [4_000, 6_000, 8_000, 10_000];

    /* Total principal locked in V3 packages */
    uint256 public totalPackagePrincipal;

    /* One user can have multiple package stakes */
    struct PackageStake {
        bool    active;         // true until unstaked
        uint8   pkgId;          // 0..3
        uint256 principal;      // EFI amount locked (wei)
        uint256 startEpoch;     // epochNumber at stake time
        uint256 endEpoch;       // startEpoch + lockDays
        uint256 lastClaimEpoch; // last epoch rewards were claimed (capped to endEpoch)
    }

    /* user => list of package stakes */
    mapping(address => PackageStake[]) public packageStakes;

    /* ============================================================
    * ========== V3: MLM/DAO REQUEST CLAIM VESTING ===============
    * ============================================================
    *
    *  User requests a claim with an option:
    *   0 = Instant  : 20% burn, 0 days lock, auto-release same tx
    *   1 = 10 days  : 15% burn, linear vest
    *   2 = 20 days  : 10% burn, linear vest
    *   3 = 30 days  :  5% burn, linear vest
    *   4 = 60 days  :  0% burn, cliff (full unlock at end)
    *
    *  DAI collateral is taken immediately (sent to treasury via _recordDaiLock)
    *  and can be released after 24h via your existing releaseDaiLock().
    *
    *  EFI mint + burn-to-dead happens ONLY on releaseReward() (except instant).
    * ============================================================ */

    enum RewardKind { MLM, DAO }

    struct RewardVesting {
        bool      active;
        RewardKind kind;

        uint256   gross;         // requested amount before burn
        uint256   releasedGross; // how much gross already released

        uint8     burnPct;       // 20/15/10/5/0
        bool      linear;        // true for 10/20/30, false for 60 cliff

        uint256   startBlock;    // request block
        uint256   endBlock;      // startBlock + lockDays*BLOCKS_PER_DAY
    }

    /* user => vesting entries */
    mapping(address => RewardVesting[]) public rewardVestings;

    /* One-time init flag for V3 */
    bool public v3Initialized;

    /* ------------------------------------------------------------
    * Events for UI indexing
    * ------------------------------------------------------------ */
    event EpochAdvanced(uint256 indexed epochNumber, uint256 epochEnd);
    event PackageStaked(address indexed user, uint8 indexed pkgId, uint256 amount, uint256 indexed stakeIdx);
    event PackageRewardClaimed(address indexed user, uint256 indexed stakeIdx, uint256 reward, uint256 uptoEpoch);
    event PackageUnstaked(address indexed user, uint256 indexed stakeIdx, uint256 principal, uint256 reward);

    event RewardClaimRequested(
        address indexed user,
        RewardKind indexed kind,
        uint256 gross,
        uint8 opt,
        uint256 indexed vestingIdx,
        uint256 startBlock,
        uint256 endBlock
    );

    event RewardReleased(
        address indexed user,
        RewardKind indexed kind,
        uint256 indexed vestingIdx,
        uint256 grossReleased,
        uint256 netMinted,
        uint256 burnMinted
    );

    event AdminLegacyUnstaked(address indexed user, uint256 totalReturned);
    event LegacyPlatinumMigrated(address indexed user, uint256 indexed legacyIdx, uint256 principal, uint256 newPackageIdx, uint256 interestPaid);














    /* ============================================================
    * V4 FINAL: USD PACKAGE STAKING + USD MLM/DAO ACCOUNTING
    * ============================================================

    V4 Smart contract architecture:

    All internal business accounting = USD 1e18

    activeSelfStakeUsd[user]
        = active self stake USD value

    levelStakeUsd[user][level]
        = active MLM/team business USD value

    unclaimedStakingRewardUsd[user]
        = pending staking reward USD

    unclaimedMLMUsd[user]
        = pending MLM reward USD

    Oracle pendingDaoReward
        = pending DAO reward USD

    All claims:
        claimStakeRewards(usdAmount)
        claimMLMRewards(usdAmount)
        claimDAORewards(usdAmount)

    Payout:
        USD converts to EFI at claim-time price

    Compatibility:
        stakeBalance remains active EFI amount
        PackageStaked / PackageUnstaked remain emitted
        DB sefi_balance_current = stakeBalance
        DB sefi_balance_usd = activeSelfStakeUsd
    */

    /// @notice Lifetime USD value staked by each user, using 1e18 decimals.
    /// @dev This value is never reduced when stake entries mature.
    ///      It is used as the base for the user's lifetime 2x reward cap.
    mapping(address => uint256) public userStakedUsd;

    /// @notice Lifetime USD value actually paid to each user as rewards, using 1e18 decimals.
    /// @dev Only USD value paid to the user increases this value.
    ///      Burned rewards do not increase this value.
    mapping(address => uint256) public userWithdrawnUsd;

    /// @notice Legacy EFI-denominated staking reward storage from an earlier patch.
    /// @dev Kept for storage/ABI compatibility. Final V4 uses unclaimedStakingRewardUsd.
    mapping(address => uint256) public unclaimedStakingReward;

    /// @notice Last epoch where staking reward was banked for each user.
    /// @dev Used by USD-based staking reward accounting.
    mapping(address => uint256) public lastStakeRewardEpoch;

    /// @notice A single FIFO stake entry used for package and migration staking.
    /// @dev Entry remains active until userWithdrawnUsd reaches matureAtUsd.
    struct SimpleStakeEntry {
        uint256 amount;       // EFI amount represented by this entry.
        uint256 stakeUsd;     // USD value of this entry, using 1e18 decimals.
        uint256 matureAtUsd;  // Cumulative USD payout threshold where this entry matures.
        uint32 ratePpm;       // Daily staking rate in PPM. Example: 6000 = 0.60%.
    }

    /// @notice FIFO stake entries per user.
    /// @dev Entries are deleted after maturity, but the array is not compacted.
    mapping(address => SimpleStakeEntry[]) public simpleStakeEntries;

    /// @notice First active FIFO entry index per user.
    /// @dev Entries before this cursor are considered matured/deleted.
    mapping(address => uint256) public simpleStakeCursor;

    /// @notice Legacy minimum stake USD value.
    /// @dev Kept for compatibility. New package staking uses simplePackageUsd.
    uint256 public minStakeUsd;

    /// @notice Total active, not-yet-matured stake value in USD, using 1e18 decimals.
    /// @dev Increases on stake/migration and decreases when FIFO entries mature.
    uint256 public totalActiveStakedUsd;

    /// @notice Pending staking reward in USD, using 1e18 decimals.
    /// @dev This is the source of truth for staking reward claims.
    mapping(address => uint256) public unclaimedStakingRewardUsd;

    /// @notice Weighted active staking reward base per user.
    /// @dev activeRewardUsdRate = sum(activeEntry.stakeUsd * activeEntry.ratePpm).
    mapping(address => uint256) public activeRewardUsdRate;

    /// @notice Active self-stake value in USD, using 1e18 decimals.
    /// @dev This is the source of truth for self-stake qualification and DB sefi_balance_usd.
    mapping(address => uint256) public activeSelfStakeUsd;

    /// @notice Active downline/team business per MLM level in USD, using 1e18 decimals.
    /// @dev This is the source of truth for MLM reward accounting.
    mapping(address => uint256[15]) public levelStakeUsd;

    /// @notice Pending MLM reward in USD, using 1e18 decimals.
    /// @dev This replaces old EFI-based unclaimedMLM for final V4 accounting.
    mapping(address => uint256) public unclaimedMLMUsd;

    /// @notice Pending DAO reward in USD, using 1e18 decimals.
    /// @dev Oracle reward values are interpreted as USD in final V4.
    mapping(address => uint256) public unclaimedDAOUsd;

    /// @notice Fixed USD package values for new staking.
    /// @dev packageId 0..7. Values use 1e18 USD decimals.
    uint256[8] public simplePackageUsd;

    /// @notice Fixed daily package reward rates.
    /// @dev PPM precision. 3000 = 0.30%, 10000 = 1.00%.
    uint32[8] public simplePackageRatePpm;

    /// @notice Daily rate for initial migration package.
    /// @dev 6000 = 0.60%.
    uint32 public initialMigrationRatePpm;

    /// @notice Final V4 initializer flag.
    /// @dev Prevents package config from being initialized twice.
    bool public v4FinalInitialized;


    
    /// @notice Emitted when final V4 package configuration is initialized or updated.
    event V4PackageConfigSet();

    /// @notice Emitted when a user stakes a new V4 package.
    /// @param user User who staked.
    /// @param packageId Selected package id. 0..7 for normal packages, 255 for migration.
    /// @param packageUsd USD value of the package, using 1e18 decimals.
    /// @param efiAmount EFI amount locked for this package.
    /// @param ratePpm Daily staking rate in PPM.
    /// @param stakeIdx FIFO stake entry index.
    event V4PackageStake(
        address indexed user,
        uint8 indexed packageId,
        uint256 packageUsd,
        uint256 efiAmount,
        uint32 ratePpm,
        uint256 indexed stakeIdx
    );

    /// @notice Emitted when an existing user is migrated into the initial package.
    /// @param user Migrated user.
    /// @param walletEfiUsed EFI taken from user's wallet.
    /// @param oldStakeEfiUsed Existing staked EFI included in migration.
    /// @param daiLockEfiUsed EFI equivalent of old DAI locks.
    /// @param totalEfiStaked Total EFI represented by migration entry.
    /// @param totalUsdStaked Total USD value represented by migration entry.
    /// @param stakeIdx FIFO stake entry index.
    event V4UserMigrated(
        address indexed user,
        uint256 walletEfiUsed,
        uint256 oldStakeEfiUsed,
        uint256 daiLockEfiUsed,
        uint256 totalEfiStaked,
        uint256 totalUsdStaked,
        uint256 indexed stakeIdx
    );














    /// @notice Initializes final V4 USD package configuration.
    /// @dev Must be called once after upgrading the proxy.
    ///      Does not migrate existing users.
    function initV4Final() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!v4FinalInitialized, "v4 initialized");

        minStakeUsd = 99e18;

        simplePackageUsd[0] = 100e18;
        simplePackageUsd[1] = 250e18;
        simplePackageUsd[2] = 500e18;
        simplePackageUsd[3] = 1000e18;
        simplePackageUsd[4] = 2500e18;
        simplePackageUsd[5] = 5000e18;
        simplePackageUsd[6] = 10000e18;
        simplePackageUsd[7] = 25000e18;

        simplePackageRatePpm[0] = 3000;
        simplePackageRatePpm[1] = 4000;
        simplePackageRatePpm[2] = 5000;
        simplePackageRatePpm[3] = 6000;
        simplePackageRatePpm[4] = 7000;
        simplePackageRatePpm[5] = 8000;
        simplePackageRatePpm[6] = 9000;
        simplePackageRatePpm[7] = 10000;

        initialMigrationRatePpm = 6000;

        v4FinalInitialized = true;

        emit V4PackageConfigSet();
    }









    /* ============================================================
    * V3: rebase() now ONLY advances epoch (NO token rebase).
    * Keeps offchain deps that call rebase()/read epochNumber intact.
    * Emits existing Rebased(...) event with profit=0.
    * ============================================================ */
    function rebase() public {
        if (block.number < epochEnd) return;

        uint256 epochs = (block.number - epochEnd) / EPOCH_LENGTH + 1;
        epochNumber += epochs;
        epochEnd    += epochs * EPOCH_LENGTH;

        // Keep the old event name for indexers (profit=0).
        emit Rebased(epochNumber, totalPackagePrincipal, 0);
    }



    /* ============================================================
    * =============== PACKAGE STAKING (V3) =======================
    * ============================================================
    *
    * Rewards:
    *  - Linear daily: reward = principal * ratePpm * days / 1e6
    *  - Accrues only up to endEpoch (no rewards after maturity)
    *  - Claimable once per day (epoch increments daily). If user waits 7 days,
    *    they get 7 days of rewards in one claim.
    *
    * Unstake:
    *  - Allowed only when epochNumber >= endEpoch
    *  - Unstake auto-claims any remaining pending rewards up to endEpoch
    *
    * NOTE:
    *  - stakeBalance is updated via _afterStake/_afterUnstake
    *  - MLM/DAO logic remains unchanged.
    * ============================================================ */






   




    /* =========================== */
    /* ========== UTILS ========== */
    /* =========================== */


    /// @dev Fixed-point exponentiation in 1e6 precision: computes (base/1e6)^exp
    /// Computes (base/1e6) ^ exp, returning result in 1e6 precision.
    /// E.g. base = 1,003,333 (i.e. 1 + 0.003333), exp = 90
    /// @param base  Fixed-point base (in 1e6 units)
    /// @param exp   Exponent (integer)
    /// @return      Result in 1e6 precision
    function _powFixed(uint256 base, uint256 exp) internal pure returns (uint256) {
        uint256 result = 1e6;          // start at “1.0” in 1e6
        uint256 b = base;              // e.g. 1,003,333
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * b) / 1e6;
            }
            b = (b * b) / 1e6;
            exp >>= 1;
        }
        return result;  // this is (1+R)^n, scaled 1e6
    }









    /* ==================================== */
    /* ========== VIEW FUNCTIONS ========== */
    /* ==================================== */



    /// @notice Get a user’s current “team stake” from the Oracle
    /// @param user  The account to query
    /// @return      Total EFI units in their entire downline
    function viewActiveTeamStake(address user) public view returns(uint256){
        return oracle.activeTeamStake(user);
    }

    

    /// @notice Get the current DAI-per-EFI price from Uniswap (×1e18)
    /// @return      Price in DAI per EFI
    function getPriceUSD() public view returns (uint256) {
        (uint112 r0, uint112 r1,) = pricePair.getReserves();
        (uint256 resE, uint256 resD) = pricePair.token0()==address(efi)
            ? (r0, r1) : (r1, r0);
        if(resE == 0 || resD == 0){
            return 0;
        } 
        return resD * 1e18 / resE;
    }

    /// @notice Get the current per-epoch reward rate (in ppm)
    /// @return      Reward rate (e.g. 3333 ⇒ 0.3333% per epoch)
    function currentRewardRate() public view returns (uint256) {
        uint256 slab = activeStakerCount / SLAB_SIZE;
        if (slab >= 10) return MIN_RATE;
        uint256 reduction = slab * 100;
        uint256 rate = BASE_RATE > reduction ? BASE_RATE - reduction : MIN_RATE;
        return rate;
    }

    /// @notice Determine `user`’s current DAO bonus tier (0–100%)
    /// @param user  The account to query
    /// @return      Bonus percentage for DAO rewards
    function currentDAOTier(address user) public view returns (uint8) {
        return oracle.userDaoTier(user);
    }

    


    /* ==================================== */
    /* ======= V4 Upgrade functions ======= */
    /* ==================================== */


//2. Staking contract changes
//2.1 Replace V4 storage block
//2.2 Add events
//2.3 Add initializer and admin package setters


//2.4 Add math helpers

    /// @notice Returns ceil(a / b).
    /// @dev Reverts if b is zero.
    /// @param a Numerator.
    /// @param b Denominator.
    /// @return Rounded-up quotient.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "div zero");
        if (a == 0) return 0;
        return ((a - 1) / b) + 1;
    }

    /// @notice Converts USD to EFI using ceiling division.
    /// @dev Used for new package staking so the contract receives enough EFI.
    /// @param usdAmount USD amount with 1e18 decimals.
    /// @param priceUSD EFI/USD price with 1e18 decimals.
    /// @return EFI amount with token decimals.
    function _usdToEfiCeil(uint256 usdAmount, uint256 priceUSD)
        internal
        pure
        returns (uint256)
    {
        require(priceUSD > 0, "bad price");
        return _ceilDiv(usdAmount * 1e18, priceUSD);
    }

    /// @notice Converts USD to EFI using floor division.
    /// @dev Used for rewards and migration conversion.
    /// @param usdAmount USD amount with 1e18 decimals.
    /// @param priceUSD EFI/USD price with 1e18 decimals.
    /// @return EFI amount with token decimals.
    function _usdToEfiFloor(uint256 usdAmount, uint256 priceUSD)
        internal
        pure
        returns (uint256)
    {
        require(priceUSD > 0, "bad price");
        return (usdAmount * 1e18) / priceUSD;
    }

    /// @notice Converts EFI amount to USD.
    /// @param efiAmount EFI amount with token decimals.
    /// @param priceUSD EFI/USD price with 1e18 decimals.
    /// @return USD value with 1e18 decimals.
    function _efiToUsd(uint256 efiAmount, uint256 priceUSD)
        internal
        pure
        returns (uint256)
    {
        require(priceUSD > 0, "bad price");
        return (efiAmount * priceUSD) / 1e18;
    }



//2.5 Replace staking function

    /// @notice Stakes a fixed USD package using EFI calculated at transaction-time price.
    /// @dev User passes packageId only. Contract calculates EFI required from package USD.
    ///      EFI is burned from user and same EFI amount is minted into this contract.
    ///      Emits PackageStaked for old off-chain compatibility.
    /// @param packageId Package id: 0=$100, 1=$250, 2=$500, 3=$1000, 4=$2500, 5=$5000, 6=$10000, 7=$25000.
    function stakeEFI(uint8 packageId) external {
        require(v4FinalInitialized, "v4 not initialized");
        require(msg.sender == tx.origin, "only EOA");
        require(!walletFrozen[msg.sender], "Wallet frozen");
        require(packageId < 8, "bad package");

        require(userStakedUsd[msg.sender] != 0 || stakeBalance[msg.sender] == 0, "init required");

        uint256 packageUsd = simplePackageUsd[packageId];
        uint32 ratePpm = simplePackageRatePpm[packageId];

        require(packageUsd > 0, "package not set");
        require(ratePpm > 0, "rate not set");

        rebase();

        uint256 priceUSD = getPriceUSD();
        require(priceUSD > 0, "bad price");

        _bankStakingReward(msg.sender);

        uint256 efiAmount = _usdToEfiCeil(packageUsd, priceUSD);
        require(efiAmount > 0, "zero EFI");

        efi.burnFromStakingContract(msg.sender, efiAmount);
        efi.mint(address(this), efiAmount);

        _createV4StakeEntry(
            msg.sender,
            efiAmount,
            packageUsd,
            ratePpm,
            packageId,
            true
        );
    }




//2.6 Add internal stake-entry creator


    /// @notice Creates a V4 stake entry and updates reward/team accounting.
    /// @dev Assumes EFI principal is already locked into this contract.
    /// @param user User receiving the stake entry.
    /// @param efiAmount EFI amount represented by this entry.
    /// @param stakeUsd USD value of the entry.
    /// @param ratePpm Daily reward rate in PPM.
    /// @param eventPackageId Package id emitted for off-chain compatibility.
    /// @param updateTeamBusiness Whether to update stakeBalance/upline business.
    function _createV4StakeEntry(
        address user,
        uint256 efiAmount,
        uint256 stakeUsd,
        uint32 ratePpm,
        uint8 eventPackageId,
        bool updateTeamBusiness
    ) internal {
        require(user != address(0), "zero user");
        require(efiAmount > 0, "zero EFI");
        require(stakeUsd > 0, "zero USD");
        require(ratePpm > 0, "zero rate");

        userStakedUsd[user] += stakeUsd;
        totalActiveStakedUsd += stakeUsd;
        activeRewardUsdRate[user] += stakeUsd * uint256(ratePpm);

        simpleStakeEntries[user].push(
            SimpleStakeEntry({
                amount: efiAmount,
                stakeUsd: stakeUsd,
                matureAtUsd: userStakedUsd[user] * 2,
                ratePpm: ratePpm
            })
        );

        uint256 stakeIdx = simpleStakeEntries[user].length - 1;

        if (updateTeamBusiness) {
            _afterStakeUsd(user, efiAmount, stakeUsd);
            totalPackagePrincipal += efiAmount;
        }

        emit PackageStaked(user, eventPackageId, efiAmount, stakeIdx);
        emit V4PackageStake(user, eventPackageId, stakeUsd, efiAmount, ratePpm, stakeIdx);
    }



//2.7 Add USD-aware stake hooks

    /// @notice Applies active self/team accounting after a stake.
    /// @dev Updates both EFI compatibility state and USD source-of-truth state.
    /// @param user User who staked.
    /// @param efiAmount EFI amount added.
    /// @param stakeUsd USD value added.
    function _afterStakeUsd(address user, uint256 efiAmount, uint256 stakeUsd) internal {
        require(!walletFrozen[user], "Wallet frozen");

        stakeBalance[user] += efiAmount;
        activeSelfStakeUsd[user] += stakeUsd;

        _distributeOverridesUsd(user, int256(efiAmount), int256(stakeUsd));
        _updateReferralQualification(user, 0);

        if (!_hasStaked[user]) {
            _hasStaked[user] = true;
            activeStakerCount++;
        }

        if (lastMLMEpoch[user] == 0) {
            lastMLMEpoch[user] = epochNumber;
        }

        _syncEligibilityAllLevels(user, 0);
    }

    /// @notice Applies active self/team accounting after a stake entry matures.
    /// @dev Reduces both EFI compatibility state and USD source-of-truth state.
    /// @param user User whose stake matured.
    /// @param efiAmount EFI amount removed.
    /// @param stakeUsd USD value removed.
    function _afterUnstakeUsd(address user, uint256 efiAmount, uint256 stakeUsd) internal {
        require(!walletFrozen[user], "Wallet frozen");

        if (stakeBalance[user] >= efiAmount) {
            stakeBalance[user] -= efiAmount;
        } else {
            stakeBalance[user] = 0;
        }

        if (activeSelfStakeUsd[user] >= stakeUsd) {
            activeSelfStakeUsd[user] -= stakeUsd;
        } else {
            activeSelfStakeUsd[user] = 0;
        }

        _distributeOverridesUsd(user, -int256(efiAmount), -int256(stakeUsd));
        _updateReferralQualification(user, 0);

        if (stakeBalance[user] == 0 && _hasStaked[user]) {
            _hasStaked[user] = false;
            if (activeStakerCount > 0) activeStakerCount--;
        }

        _syncEligibilityAllLevels(user, 0);
    }



//2.8 Replace qualification helpers


    /// @notice Returns active EFI stake used for legacy compatibility.
    /// @dev Final qualification should use _selfStakedUsdForQualification().
    /// @param u User address.
    /// @return Active EFI stake.
    function _selfStakedForQualification(address u) internal view returns (uint256) {
        return stakeBalance[u];
    }

    /// @notice Returns active USD self-stake used for final qualification.
    /// @param u User address.
    /// @return Active self-stake USD with 1e18 decimals.
    function _selfStakedUsdForQualification(address u) internal view returns (uint256) {
        return activeSelfStakeUsd[u];
    }

    /// @notice Counts active direct downlines using USD self-stake.
    /// @dev The second parameter is kept for ABI/internal compatibility and ignored.
    /// @param user User whose directs are counted.
    /// @return activeDownlineCount Number of directs with at least $100 active self stake.
    function getRealTimeActiveDirectDownlinesCount(address user, uint256)
        public
        view
        returns (uint256 activeDownlineCount)
    {
        address[] memory directs = tree.getDirectDownlines(user);

        for (uint256 i = 0; i < directs.length; ++i) {
            if (activeSelfStakeUsd[directs[i]] >= 100e18) {
                activeDownlineCount++;
            }
        }
    }

    /// @notice Returns effective qualified direct count.
    /// @dev Uses cache for large users and realtime count for small users.
    /// @param u User address.
    /// @return Effective qualified direct count.
    function _effectiveDirects(address u, uint256) internal view returns (uint256) {
        uint256 directsTotal = tree.getDirectDownlinesTotal(u);

        if (directsTotal < noOfDownlinesForCache) {
            return getRealTimeActiveDirectDownlinesCount(u, 0);
        }

        uint256 cached = qualifiedDirectReferralsCount[u];

        if (cached == 0) {
            return getRealTimeActiveDirectDownlinesCount(u, 0);
        }

        return cached;
    }

    /// @notice Updates whether a direct referral is qualified.
    /// @dev Qualification is now based on activeSelfStakeUsd >= $100.
    /// @param user Direct referral whose qualification may have changed.
    function _updateReferralQualification(address user, uint256) internal {
        address up = tree.getReferrer(user);
        if (up == address(0)) return;

        bool wasQualified = isReferralQualified[up][user];
        bool isNowQualified = activeSelfStakeUsd[user] >= 100e18;

        if (wasQualified == isNowQualified) return;

        isReferralQualified[up][user] = isNowQualified;

        uint256 directsTotal = tree.getDirectDownlinesTotal(up);

        if (directsTotal < noOfDownlinesForCache) {
            _syncEligibilityAllLevels(up, 0);
            return;
        }

        uint256 cached = qualifiedDirectReferralsCount[up];

        if (cached == 0) {
            qualifiedDirectReferralsCount[up] = getRealTimeActiveDirectDownlinesCount(up, 0);
            _syncEligibilityAllLevels(up, 0);
            return;
        }

        if (isNowQualified) {
            qualifiedDirectReferralsCount[up] = cached + 1;
        } else if (cached > 0) {
            qualifiedDirectReferralsCount[up] = cached - 1;
        }

        _syncEligibilityAllLevels(up, 0);
    }




//2.9 Replace MLM eligibility and banking


    /// @notice Synchronizes MLM eligibility for all 15 levels.
    /// @dev Eligibility is based on USD self-stake and qualified directs.
    /// @param u User address.
    function _syncEligibilityAllLevels(address u, uint256) internal {
        uint256 current = epochNumber;
        uint256 selfUSD = activeSelfStakeUsd[u];
        uint256 effDirects = _effectiveDirects(u, 0);

        for (uint8 lvl = 0; lvl < 15; ++lvl) {
            bool eligible = effDirects >= reqDirects[lvl] && selfUSD >= reqSelfStakeUSD[lvl];

            if (eligible) {
                if (eligibilityOnSince[u][lvl] == 0) {
                    eligibilityOnSince[u][lvl] = current;
                    if (lastLevelUpdateEpoch[u][lvl] < current) {
                        lastLevelUpdateEpoch[u][lvl] = current;
                    }
                }
            } else {
                if (eligibilityOnSince[u][lvl] != 0) {
                    _bankLevelAccrualUsdClamped(u, lvl, mlmRatePpm, selfUSD, effDirects);
                    eligibilityOnSince[u][lvl] = 0;
                    lastLevelUpdateEpoch[u][lvl] = current;
                }
            }
        }
    }

    /// @notice Banks USD-denominated MLM accrual for one level.
    /// @dev Uses levelStakeUsd as principal instead of EFI-denominated levelStake.
    /// @param u User whose level reward is banked.
    /// @param lvl MLM level index.
    /// @param rate MLM compounding rate in PPM.
    /// @param selfUSD User active self-stake USD.
    /// @param effDirects Effective qualified direct count.
    function _bankLevelAccrualUsdClamped(
        address u,
        uint8 lvl,
        uint256 rate,
        uint256 selfUSD,
        uint256 effDirects
    ) internal {
        uint256 current = epochNumber;

        uint256 onSince = eligibilityOnSince[u][lvl];
        if (onSince == 0) {
            if (lastLevelUpdateEpoch[u][lvl] != current) {
                lastLevelUpdateEpoch[u][lvl] = current;
            }
            return;
        }

        if (effDirects < reqDirects[lvl] || selfUSD < reqSelfStakeUSD[lvl]) {
            if (lastLevelUpdateEpoch[u][lvl] != current) {
                lastLevelUpdateEpoch[u][lvl] = current;
            }
            return;
        }

        uint256 start = lastLevelUpdateEpoch[u][lvl];
        uint256 last = lastMLMEpoch[u];

        if (start < last) start = last;
        if (start < onSince) start = onSince;

        if (current <= start) {
            if (lastLevelUpdateEpoch[u][lvl] != current) {
                lastLevelUpdateEpoch[u][lvl] = current;
            }
            return;
        }

        uint256 principalUsd = levelStakeUsd[u][lvl];

        if (principalUsd == 0) {
            if (lastLevelUpdateEpoch[u][lvl] != current) {
                lastLevelUpdateEpoch[u][lvl] = current;
            }
            return;
        }

        uint256 epochs = current - start;
        uint256 factor = _powFixed(1_000_000 + rate, epochs);
        uint256 growth = factor - 1_000_000;

        unclaimedMLMUsd[u] += (((principalUsd * growth) / 1_000_000) * overrideRates[lvl]) / 100;

        if (lastLevelUpdateEpoch[u][lvl] != current) {
            lastLevelUpdateEpoch[u][lvl] = current;
        }
    }

    /// @notice Distributes stake changes to uplines in both EFI and USD.
    /// @dev EFI levelStake is maintained for compatibility; USD levelStakeUsd is source of truth.
    /// @param user Downline whose stake changed.
    /// @param efiDelta Signed EFI change.
    /// @param usdDelta Signed USD change.
    function _distributeOverridesUsd(
        address user,
        int256 efiDelta,
        int256 usdDelta
    ) internal {
        address up = tree.getReferrer(user);
        if (up == address(0)) return;

        uint256 rate = mlmRatePpm;

        for (uint8 lvl = 0; lvl < 15 && up != address(0); ++lvl) {
            uint256 selfUSD = activeSelfStakeUsd[up];
            uint256 effDirects = _effectiveDirects(up, 0);

            _bankLevelAccrualUsdClamped(up, lvl, rate, selfUSD, effDirects);

            if (efiDelta >= 0) {
                levelStake[up][lvl] += uint256(efiDelta);
            } else {
                uint256 d = uint256(-efiDelta);
                levelStake[up][lvl] = levelStake[up][lvl] >= d ? levelStake[up][lvl] - d : 0;
            }

            if (usdDelta >= 0) {
                levelStakeUsd[up][lvl] += uint256(usdDelta);
            } else {
                uint256 dUsd = uint256(-usdDelta);
                levelStakeUsd[up][lvl] = levelStakeUsd[up][lvl] >= dUsd ? levelStakeUsd[up][lvl] - dUsd : 0;
            }

            _syncEligibilityAllLevels(up, 0);

            up = tree.getReferrer(up);
        }
    }




//2.10 Replace reward banking/views/settlement/claims

    /// @notice Banks staking rewards in USD up to current epoch.
    /// @param user User whose staking reward is banked.
    function _bankStakingReward(address user) internal {
        uint256 last = lastStakeRewardEpoch[user];

        if (last == 0) {
            lastStakeRewardEpoch[user] = epochNumber;
            return;
        }

        if (epochNumber <= last) return;

        uint256 weightedRate = activeRewardUsdRate[user];

        if (weightedRate > 0) {
            uint256 epochs = epochNumber - last;
            unclaimedStakingRewardUsd[user] += (weightedRate * epochs) / 1_000_000;
        }

        lastStakeRewardEpoch[user] = epochNumber;
    }

    /// @notice Returns pending staking reward in USD.
    /// @param user User address.
    /// @return totalUsd Pending staking reward USD.
    function viewStakeRewards(address user) public view returns (uint256 totalUsd) {
        totalUsd = unclaimedStakingRewardUsd[user];

        uint256 last = lastStakeRewardEpoch[user];
        if (last == 0 || epochNumber <= last) return totalUsd;

        uint256 weightedRate = activeRewardUsdRate[user];
        if (weightedRate == 0) return totalUsd;

        uint256 epochs = epochNumber - last;
        totalUsd += (weightedRate * epochs) / 1_000_000;
    }

    /// @notice Returns pending MLM reward in USD.
    /// @param user User address.
    /// @return totalUsd Pending MLM reward USD.
    function viewPendingMLMRewards(address user) public view returns (uint256 totalUsd) {
        totalUsd = unclaimedMLMUsd[user];

        uint256 last = lastMLMEpoch[user];
        uint256 current = epochNumber;
        if (current <= last) return totalUsd;

        uint256 rate = mlmRatePpm;
        uint256 selfUSD = activeSelfStakeUsd[user];
        uint256 effDirects = _effectiveDirects(user, 0);

        for (uint8 lvl = 0; lvl < 15; ++lvl) {
            uint256 onSince = eligibilityOnSince[user][lvl];
            if (onSince == 0) continue;

            uint256 principalUsd = levelStakeUsd[user][lvl];
            if (principalUsd == 0) continue;

            if (effDirects < reqDirects[lvl] || selfUSD < reqSelfStakeUSD[lvl]) continue;

            uint256 start = lastLevelUpdateEpoch[user][lvl];
            if (start < last) start = last;
            if (start < onSince) start = onSince;
            if (current <= start) continue;

            uint256 epochs = current - start;
            uint256 factor = _powFixed(1_000_000 + rate, epochs);
            uint256 growth = factor - 1_000_000;

            uint256 compoundedUsd = (principalUsd * growth) / 1_000_000;
            totalUsd += (compoundedUsd * overrideRates[lvl]) / 100;
        }
    }

    /// @notice Returns pending DAO reward in USD.
    /// @dev Oracle reward values are interpreted as USD in final V4.
    /// @param user User address.
    /// @return totalUsd Pending DAO reward USD.
    function viewPendingDAORewards(address user) public view returns (uint256 totalUsd) {
        totalUsd = unclaimedDAOUsd[user];
        totalUsd += oracle.viewAvailableDaoRewards(user, epochNumber);
    }

    /// @notice Settles a USD-denominated reward into EFI payout/burn.
    /// @dev All reward types use this final settlement function.
    /// @param user User receiving the paid portion.
    /// @param rewardUsd Gross reward USD to process.
    /// @param priceUSD EFI/USD claim-time price.
    /// @return paidEfi EFI paid to user.
    /// @return burnedEfi EFI burned.
    /// @return paidUsd USD counted toward user's 2x cap.
    function _settleRewardUsd(
        address user,
        uint256 rewardUsd,
        uint256 priceUSD
    )
        internal
        returns (uint256 paidEfi, uint256 burnedEfi, uint256 paidUsd)
    {
        if (rewardUsd == 0) return (0, 0, 0);

        uint256 maxPayoutUsd = userStakedUsd[user] * 2;
        uint256 availableUsd = userWithdrawnUsd[user] < maxPayoutUsd
            ? maxPayoutUsd - userWithdrawnUsd[user]
            : 0;

        uint256 burnedUsd;

        if (rewardUsd <= availableUsd) {
            paidUsd = rewardUsd;
        } else {
            paidUsd = availableUsd;
            burnedUsd = rewardUsd - paidUsd;
        }

        paidEfi = paidUsd > 0 ? _usdToEfiFloor(paidUsd, priceUSD) : 0;
        burnedEfi = burnedUsd > 0 ? _usdToEfiFloor(burnedUsd, priceUSD) : 0;

        uint256 totalNeeded = paidEfi + burnedEfi;
        require(efi.balanceOf(address(this)) >= totalNeeded, "insufficient pool");

        if (paidEfi > 0) require(efi.transfer(user, paidEfi), "pay failed");
        if (burnedEfi > 0) require(efi.transfer(BURN_ADDRESS, burnedEfi), "burn failed");

        if (rewardUsd >= availableUsd) {
            userWithdrawnUsd[user] = maxPayoutUsd;
        } else {
            userWithdrawnUsd[user] += paidUsd;
        }
    }



    /// @notice Claims staking reward in USD.
    /// @param usdAmount USD amount to claim, using 1e18 decimals.
    /// @return paidEfi EFI paid to user.
    /// @return burnedEfi EFI burned.
    function claimStakeRewards(uint256 usdAmount)
        external
        returns (uint256 paidEfi, uint256 burnedEfi)
    {
        require(v4FinalInitialized, "v4 not initialized");
        require(msg.sender == tx.origin, "only EOA");
        require(!walletFrozen[msg.sender], "Wallet frozen");
        require(userStakedUsd[msg.sender] > 0, "no stake cap");

        rebase();
        _bankStakingReward(msg.sender);

        uint256 availableUsd = unclaimedStakingRewardUsd[msg.sender];
        require(usdAmount > 0 && usdAmount <= availableUsd, "Amount too large");

        unclaimedStakingRewardUsd[msg.sender] = availableUsd - usdAmount;

        uint256 priceUSD = getPriceUSD();
        require(priceUSD > 0, "bad price");

        (paidEfi, burnedEfi, ) = _settleRewardUsd(msg.sender, usdAmount, priceUSD);

        _processMaturedStakeEntries(msg.sender, priceUSD);

        emit PackageRewardClaimed(msg.sender, 0, paidEfi, epochNumber);
    }






    /// @notice Claims MLM reward in USD.
    /// @param usdAmount USD amount to claim, using 1e18 decimals.
    /// @return paidEfi EFI paid to user.
    /// @return burnedEfi EFI burned.
    function claimMLMRewards(uint256 usdAmount)
        external
        returns (uint256 paidEfi, uint256 burnedEfi)
    {
        require(v4FinalInitialized, "v4 not initialized");
        require(msg.sender == tx.origin, "only EOA");
        require(!walletFrozen[msg.sender], "Wallet frozen");
        require(userStakedUsd[msg.sender] > 0, "no stake cap");

        rebase();
        _bankStakingReward(msg.sender);

        uint256 cur = epochNumber;
        uint256 availableUsd = viewPendingMLMRewards(msg.sender);

        require(usdAmount > 0 && usdAmount <= availableUsd, "Amount too large");

        lastMLMEpoch[msg.sender] = cur;
        unclaimedMLMUsd[msg.sender] = availableUsd - usdAmount;

        uint256 priceUSD = getPriceUSD();
        require(priceUSD > 0, "bad price");

        (paidEfi, burnedEfi, ) = _settleRewardUsd(msg.sender, usdAmount, priceUSD);

        _processMaturedStakeEntries(msg.sender, priceUSD);

        emit ClaimedMLM(msg.sender, paidEfi);
    }







    /// @notice Claims DAO reward in USD.
    /// @dev Oracle reward values are interpreted as USD.
    /// @param usdAmount USD amount to claim, using 1e18 decimals.
    /// @return paidEfi EFI paid to user.
    /// @return burnedEfi EFI burned.
    function claimDAORewards(uint256 usdAmount)
        external
        returns (uint256 paidEfi, uint256 burnedEfi)
    {
        require(v4FinalInitialized, "v4 not initialized");
        require(msg.sender == tx.origin, "only EOA");
        require(!walletFrozen[msg.sender], "Wallet frozen");
        require(userStakedUsd[msg.sender] > 0, "no stake cap");

        rebase();
        _bankStakingReward(msg.sender);

        uint256 freshUsd = oracle.viewAvailableDaoRewards(msg.sender, epochNumber);

        if (freshUsd > 0) {
            oracle.claimDaoRewards(msg.sender, epochNumber);
            unclaimedDAOUsd[msg.sender] += freshUsd;
        }

        uint256 availableUsd = unclaimedDAOUsd[msg.sender];
        require(usdAmount > 0 && usdAmount <= availableUsd, "Amount too large");

        unclaimedDAOUsd[msg.sender] = availableUsd - usdAmount;

        uint256 priceUSD = getPriceUSD();
        require(priceUSD > 0, "bad price");

        (paidEfi, burnedEfi, ) = _settleRewardUsd(msg.sender, usdAmount, priceUSD);

        _processMaturedStakeEntries(msg.sender, priceUSD);

        emit DAOClaim(msg.sender, oracle.userDaoTier(msg.sender), paidEfi, epochNumber);
    }





//2.11 Replace maturity processor

    /// @notice Processes matured FIFO stake entries for a user.
    /// @dev Matured entries are removed from staking rewards, self stake, MLM USD business, and off-chain active balance.
    /// @param user User whose entries are processed.
    /// @param priceUSD Current EFI/USD price. Kept for compatibility with old call sites.
    function _processMaturedStakeEntries(address user, uint256 priceUSD) internal {
        priceUSD; // silence unused variable if compiler warns

        uint256 i = simpleStakeCursor[user];
        uint256 len = simpleStakeEntries[user].length;

        while (i < len) {
            SimpleStakeEntry storage entry = simpleStakeEntries[user][i];

            if (userWithdrawnUsd[user] < entry.matureAtUsd) break;

            uint256 reduceAmount = entry.amount;
            if (reduceAmount > stakeBalance[user]) reduceAmount = stakeBalance[user];

            uint256 reduceUsd = entry.stakeUsd;
            uint256 reduceWeightedRate = entry.stakeUsd * uint256(entry.ratePpm);

            _afterUnstakeUsd(user, reduceAmount, reduceUsd);

            totalPackagePrincipal = totalPackagePrincipal >= reduceAmount
                ? totalPackagePrincipal - reduceAmount
                : 0;

            totalActiveStakedUsd = totalActiveStakedUsd >= reduceUsd
                ? totalActiveStakedUsd - reduceUsd
                : 0;

            activeRewardUsdRate[user] = activeRewardUsdRate[user] >= reduceWeightedRate
                ? activeRewardUsdRate[user] - reduceWeightedRate
                : 0;

            emit PackageUnstaked(user, i, reduceAmount, 0);

            delete simpleStakeEntries[user][i];

            unchecked { ++i; }
        }

        simpleStakeCursor[user] = i;
    }

    /// @notice Processes matured entries with a bounded loop.
    /// @dev Anyone can call because it only removes already-matured active business.
    /// @param user User whose entries should be processed.
    /// @param maxCount Max entries to process.
    function processMaturedStakeEntries(address user, uint256 maxCount) external {
        require(user != address(0), "zero user");
        require(maxCount > 0, "zero max");

        rebase();
        _bankStakingReward(user);

        uint256 i = simpleStakeCursor[user];
        uint256 len = simpleStakeEntries[user].length;
        uint256 processed;

        while (i < len && processed < maxCount) {
            SimpleStakeEntry storage entry = simpleStakeEntries[user][i];

            if (userWithdrawnUsd[user] < entry.matureAtUsd) break;

            uint256 reduceAmount = entry.amount;
            if (reduceAmount > stakeBalance[user]) reduceAmount = stakeBalance[user];

            uint256 reduceUsd = entry.stakeUsd;
            uint256 reduceWeightedRate = entry.stakeUsd * uint256(entry.ratePpm);

            _afterUnstakeUsd(user, reduceAmount, reduceUsd);

            totalPackagePrincipal = totalPackagePrincipal >= reduceAmount
                ? totalPackagePrincipal - reduceAmount
                : 0;

            totalActiveStakedUsd = totalActiveStakedUsd >= reduceUsd
                ? totalActiveStakedUsd - reduceUsd
                : 0;

            activeRewardUsdRate[user] = activeRewardUsdRate[user] >= reduceWeightedRate
                ? activeRewardUsdRate[user] - reduceWeightedRate
                : 0;

            emit PackageUnstaked(user, i, reduceAmount, 0);

            delete simpleStakeEntries[user][i];

            unchecked {
                ++i;
                ++processed;
            }
        }

        simpleStakeCursor[user] = i;
    }




//2.12 Add read/admin helpers

    /// @notice Returns remaining USD payout capacity under 2x cap.
    /// @param user User address.
    /// @return Remaining USD amount with 1e18 decimals.
    function withdrawableUsd(address user) public view returns (uint256) {
        uint256 maxPayout = userStakedUsd[user] * 2;

        if (userWithdrawnUsd[user] >= maxPayout) return 0;

        return maxPayout - userWithdrawnUsd[user];
    }

    /// @notice Returns number of simple stake entries for a user.
    /// @param user User address.
    /// @return Entry count.
    function getSimpleStakeEntryCount(address user) external view returns (uint256) {
        return simpleStakeEntries[user].length;
    }

    /// @notice Returns old DAI lock summary for a user.
    /// @param user User address.
    /// @return lockCount Number of DAI lock entries.
    /// @return totalDai Total locked DAI.
    function viewDaiLockSummary(address user)
        external
        view
        returns (uint256 lockCount, uint256 totalDai)
    {
        DaiLock[] storage locks = daiLocks[user];
        lockCount = locks.length;

        for (uint256 i = 0; i < lockCount; ++i) {
            totalDai += locks[i].daiAmount;
        }
    }

    /// @notice Quotes EFI needed for a V4 package stake.
    /// @param packageId Package id 0..7.
    /// @return packageUsd Package USD value.
    /// @return ratePpm Daily reward rate.
    /// @return efiAmount Required EFI at current price.
    function quoteV4PackageStake(uint8 packageId)
        external
        view
        returns (uint256 packageUsd, uint32 ratePpm, uint256 efiAmount)
    {
        require(packageId < 8, "bad package");

        packageUsd = simplePackageUsd[packageId];
        ratePpm = simplePackageRatePpm[packageId];

        require(packageUsd > 0, "package not set");
        require(ratePpm > 0, "rate not set");

        uint256 priceUSD = getPriceUSD();
        require(priceUSD > 0, "bad price");

        efiAmount = _usdToEfiCeil(packageUsd, priceUSD);
    }































    /* ==================================== */
    /* ========== ADMIN FUNCTIONS ========= */
    /* ==================================== */


    /// @notice Update the staker‐count threshold for MLM fee burn
    /// @param _mlmFeeThreshold  New threshold of `activeStakerCount`
    function setMlmFeeThreshold(uint256 _mlmFeeThreshold, uint256 _efiSupplyThreshold, uint256 _activeStakerCount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MLM_FEE_THRESHOLD = _mlmFeeThreshold;
        EFI_SUPPLY_THRESHOLD_BURNING = _efiSupplyThreshold;
        activeStakerCount = _activeStakerCount;
        emit SetMlmFeeThreshold(_mlmFeeThreshold);
    }

    //@notice set epoch variables
    function setEpochVariables(uint256 _EPOCH_LENGTH, uint256 _BASE_RATE, uint256 _MIN_RATE, uint256 _SLAB_SIZE, uint256 _MLM_FEE_PCT, uint256 _DAI_LOCK_DELAY, uint256 _epochNumber, uint256 _epochEnd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EPOCH_LENGTH = _EPOCH_LENGTH;
        BASE_RATE = _BASE_RATE;
        MIN_RATE = _MIN_RATE;
        SLAB_SIZE = _SLAB_SIZE;
        MLM_FEE_PCT = _MLM_FEE_PCT;
        DAI_LOCK_DELAY = _DAI_LOCK_DELAY;
        epochNumber = _epochNumber;
        epochEnd = _epochEnd;
    }

    //@notice setLevelStake set Level Stake
    function setLevelStake(address user, uint256[15] memory levels ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint8 level = 0; level < levels.length; level++){
            levelStake[user][level] = levels[level];
        }
    }

    //@notice setMlmData set Mlm Data
    function setMlmData(address user, uint256 _lastMLMEpoch, uint256 _qualifiedDirectReferralsCount, uint8 _noOfDownlinesForCache) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lastMLMEpoch[user] = _lastMLMEpoch;
        qualifiedDirectReferralsCount[user] = _qualifiedDirectReferralsCount;
        noOfDownlinesForCache = _noOfDownlinesForCache;
    }

    //@notice unclaimed MLM and DAO
    function setUnclaimed(address user, uint256 _unclaimedMLM, uint256 _unclaimedDAO) external onlyRole(DEFAULT_ADMIN_ROLE) {
        unclaimedMLM[user] = _unclaimedMLM;
        unclaimedDAO[user] = _unclaimedDAO;
    }


    
    

    /// @notice Admin: freeze or unfreeze a wallet from all staking-related actions
    /// @param user    The address to (un)freeze
    /// @param frozen true to freeze, false to unfreeze
    function setWalletFrozen(address user, bool frozen)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "Zero user");
        walletFrozen[user] = frozen;
    }

    function setMinStakeUsd(uint256 _minStakeUsd) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minStakeUsd > 0, "zero min");
        minStakeUsd = _minStakeUsd;
    }




    /// @notice Updates a single V4 package.
    /// @dev Use only before opening public staking or for approved future package changes.
    /// @param packageId Package id from 0 to 7.
    /// @param packageUsd Package USD value, using 1e18 decimals.
    /// @param ratePpm Daily reward rate in PPM.
    function setV4Package(
        uint8 packageId,
        uint256 packageUsd,
        uint32 ratePpm
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(packageId < 8, "bad package");
        require(packageUsd > 0, "zero package");
        require(ratePpm > 0 && ratePpm <= 1_000_000, "bad rate");

        simplePackageUsd[packageId] = packageUsd;
        simplePackageRatePpm[packageId] = ratePpm;

        emit V4PackageConfigSet();
    }

    /// @notice Updates initial migration package reward rate.
    /// @dev 6000 = 0.60%. Use only before migration unless governance approves otherwise.
    /// @param ratePpm Daily reward rate in PPM.
    function setInitialMigrationRatePpm(uint32 ratePpm)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(ratePpm > 0 && ratePpm <= 1_000_000, "bad rate");
        initialMigrationRatePpm = ratePpm;
    }


    /// @notice Admin correction for withdrawn USD.
    /// @dev If this crosses maturity thresholds, call processMaturedStakeEntries afterward.
    function setUserWithdrawnUsd(address user, uint256 withdrawnUsd)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        userWithdrawnUsd[user] = withdrawnUsd;
    }

    /// @notice Admin correction for global active staked USD.
    function setTotalActiveStakedUsd(uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        totalActiveStakedUsd = value;
    }

    /// @notice Admin correction for user's active reward USD rate.
    function setActiveRewardUsdRate(address user, uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        activeRewardUsdRate[user] = value;
    }

    /// @notice Admin correction for pending staking reward USD.
    function setUnclaimedStakingRewardUsd(address user, uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        unclaimedStakingRewardUsd[user] = value;
    }

    /// @notice Admin correction for active self-stake USD.
    function setActiveSelfStakeUsd(address user, uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        activeSelfStakeUsd[user] = value;
    }

    /// @notice Admin correction for pending MLM USD.
    function setUnclaimedMLMUsd(address user, uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        unclaimedMLMUsd[user] = value;
    }

    /// @notice Admin correction for pending DAO USD.
    function setUnclaimedDAOUsd(address user, uint256 value)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(user != address(0), "zero user");
        unclaimedDAOUsd[user] = value;
    }











    /// @notice Stakes full current wallet EFI balance as fresh V4 stake.
    /// @dev Production-safe wallet-lock function.
    ///      This function:
    ///      - reads each user's current EFI wallet balance,
    ///      - banks existing staking rewards before changing reward weight,
    ///      - burns wallet EFI from user,
    ///      - mints same EFI into this staking contract,
    ///      - creates a fresh V4 stake entry at fixed $3.5 accounting price,
    ///      - applies normal self/team accounting through _afterStakeUsd().
    ///
    ///      Duplicate wallets are safe: after first successful call, wallet balance becomes zero
    ///      and later duplicate entries are skipped.
    ///
    ///      This version is for the current production implementation where:
    ///      _afterStakeUsd(address user, uint256 efiAmount, uint256 stakeUsd)
    ///
    /// @param users Users whose full wallet EFI should be staked.
    function adminStakeFullWalletEfiToV4(address[] calldata users, uint256 priceUsd)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(v4FinalInitialized, "v4 not initialized");
        require(initialMigrationRatePpm > 0, "bad migration rate");
        require(priceUsd > 0, "bad price");

        rebase();

        for (uint256 i = 0; i < users.length; ++i) {
            address user = users[i];

            require(user != address(0), "zero user");
            require(!walletFrozen[user], "Wallet frozen");

            uint256 walletEfi = efi.balanceOf(user);

            if (walletEfi == 0) {
                continue;
            }

            uint256 walletUsd = _efiToUsd(walletEfi, priceUsd);

            if (walletUsd == 0) {
                continue;
            }

            /*
            * Critical:
            * Bank existing staking reward before increasing activeRewardUsdRate.
            * Otherwise the new wallet stake could earn rewards for previous epochs.
            */
            _bankStakingReward(user);

            /*
            * Lock wallet EFI as staking principal.
            * This assumes the staking contract/token has authority to burn from the user.
            */
            efi.burnFromStakingContract(user, walletEfi);
            efi.mint(address(this), walletEfi);

            /*
            * Lifetime USD cap accounting.
            */
            userStakedUsd[user] += walletUsd;

            /*
            * Active global USD accounting.
            */
            totalActiveStakedUsd += walletUsd;

            /*
            * User staking reward weight.
            */
            activeRewardUsdRate[user] += walletUsd * uint256(initialMigrationRatePpm);

            /*
            * FIFO maturity entry.
            */
            simpleStakeEntries[user].push(
                SimpleStakeEntry({
                    amount: walletEfi,
                    stakeUsd: walletUsd,
                    matureAtUsd: userStakedUsd[user] * 2,
                    ratePpm: initialMigrationRatePpm
                })
            );

            uint256 stakeIdx = simpleStakeEntries[user].length - 1;

            /*
            * Active self-stake + MLM/team business accounting.
            */
            _afterStakeUsd(user, walletEfi, walletUsd);

            /*
            * Active EFI principal tracker.
            */
            totalPackagePrincipal += walletEfi;

            emit PackageStaked(user, 255, walletEfi, stakeIdx);

            emit V4PackageStake(
                user,
                255,
                walletUsd,
                walletEfi,
                initialMigrationRatePpm,
                stakeIdx
            );

            emit V4UserMigrated(
                user,
                walletEfi,
                0,
                0,
                walletEfi,
                walletUsd,
                stakeIdx
            );
        }
    }












    
    
}