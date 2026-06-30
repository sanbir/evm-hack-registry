// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

// OpenZeppelin Contracts (last updated v5.0.0) (access/AccessControl.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (access/IAccessControl.sol)

/**
 * @dev External interface of AccessControl declared to support ERC165 detection.
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
     * {RoleAdminChanged} not being emitted signaling this.
     */
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    /**
     * @dev Emitted when `account` is granted `role`.
     *
     * `sender` is the account that originated the contract call, an admin role
     * bearer except when using {AccessControl-_setupRole}.
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

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Context.sol)

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
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/ERC165.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
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
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

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

    /**
     * @dev See {IERC165-supportsInterface}.
     */
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
     * @dev Attempts to revoke `role` to `account` and returns a boolean indicating if `role` was revoked.
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

// OpenZeppelin Contracts (last updated v5.0.0) (utils/cryptography/ECDSA.sol)

/**
 * @dev Elliptic Curve Digital Signature Algorithm (ECDSA) operations.
 *
 * These functions can be used to verify that a message was signed by the holder
 * of the private keys of a given address.
 */
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS
    }

    /**
     * @dev The signature derives the `address(0)`.
     */
    error ECDSAInvalidSignature();

    /**
     * @dev The signature has an invalid length.
     */
    error ECDSAInvalidSignatureLength(uint256 length);

    /**
     * @dev The signature has an S value that is in the upper half order.
     */
    error ECDSAInvalidSignatureS(bytes32 s);

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with `signature` or an error. This will not
     * return address(0) without also returning an error description. Errors are documented using an enum (error type)
     * and a bytes32 providing additional information about the error.
     *
     * If no error is returned, then the address can be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     *
     * Documentation for signature generation:
     * - with https://web3js.readthedocs.io/en/v1.3.4/web3-eth-accounts.html#sign[Web3.js]
     * - with https://docs.ethers.io/v5/api/signer/#Signer-signMessage[ethers]
     */
    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError, bytes32) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            // ecrecover takes the signature parameters, and the only way to get them
            // currently is to use assembly.
            /// @solidity memory-safe-assembly
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength, bytes32(signature.length));
        }
    }

    /**
     * @dev Returns the address that signed a hashed message (`hash`) with
     * `signature`. This address can then be used for verification purposes.
     *
     * The `ecrecover` EVM precompile allows for malleable (non-unique) signatures:
     * this function rejects them by requiring the `s` value to be in the lower
     * half order, and the `v` value to be either 27 or 28.
     *
     * IMPORTANT: `hash` _must_ be the result of a hash operation for the
     * verification to be secure: it is possible to craft signatures that
     * recover to arbitrary addresses for non-hashed data. A safe way to ensure
     * this is by receiving a hash of the original message (which may otherwise
     * be too long), and then calling {MessageHashUtils-toEthSignedMessageHash} on it.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, signature);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `r` and `vs` short-signature fields separately.
     *
     * See https://eips.ethereum.org/EIPS/eip-2098[EIP-2098 short signatures]
     */
    function tryRecover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address, RecoverError, bytes32) {
        unchecked {
            bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            // We do not check for an overflow here since the shift operation results in 0 or 1.
            uint8 v = uint8((uint256(vs) >> 255) + 27);
            return tryRecover(hash, v, r, s);
        }
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `r and `vs` short-signature fields separately.
     */
    function recover(bytes32 hash, bytes32 r, bytes32 vs) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, r, vs);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Overload of {ECDSA-tryRecover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function tryRecover(
        bytes32 hash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal pure returns (address, RecoverError, bytes32) {
        // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
        // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
        // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
        // signatures from current libraries generate a unique signature with an s-value in the lower half order.
        //
        // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
        // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
        // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
        // these malleable signatures as well.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS, s);
        }

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature, bytes32(0));
        }

        return (signer, RecoverError.NoError, bytes32(0));
    }

    /**
     * @dev Overload of {ECDSA-recover} that receives the `v`,
     * `r` and `s` signature fields separately.
     */
    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error, bytes32 errorArg) = tryRecover(hash, v, r, s);
        _throwError(error, errorArg);
        return recovered;
    }

    /**
     * @dev Optionally reverts with the corresponding custom error according to the `error` argument provided.
     */
    function _throwError(RecoverError error, bytes32 errorArg) private pure {
        if (error == RecoverError.NoError) {
            return; // no error: do nothing
        } else if (error == RecoverError.InvalidSignature) {
            revert ECDSAInvalidSignature();
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert ECDSAInvalidSignatureLength(uint256(errorArg));
        } else if (error == RecoverError.InvalidSignatureS) {
            revert ECDSAInvalidSignatureS(errorArg);
        }
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Strings.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    /**
     * @dev Muldiv operation overflow.
     */
    error MathOverflowedMulDiv();

    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            return a / b;
        }

        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     * @dev Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = x * y. Compute the product mod 2^256 and mod 2^256 - 1, then use
            // use the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2^256 + prod0.
            uint256 prod0 = x * y; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(x, y, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Handle non-overflow cases, 256 by 256 division.
            if (prod1 == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return prod0 / denominator;
            }

            // Make sure the result is less than 2^256. Also prevents denominator == 0.
            if (denominator <= prod1) {
                revert MathOverflowedMulDiv();
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [prod1 prod0] by twos.
                prod0 := div(prod0, twos)

                // Flip twos such that it is 2^256 / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from prod1 into prod0.
            prod0 |= prod1 * twos;

            // Invert denominator mod 2^256. Now that denominator is an odd number, it has an inverse modulo 2^256 such
            // that denominator * inv = 1 mod 2^256. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv = 1 mod 2^4.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2^8
            inverse *= 2 - denominator * inverse; // inverse mod 2^16
            inverse *= 2 - denominator * inverse; // inverse mod 2^32
            inverse *= 2 - denominator * inverse; // inverse mod 2^64
            inverse *= 2 - denominator * inverse; // inverse mod 2^128
            inverse *= 2 - denominator * inverse; // inverse mod 2^256

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2^256. Since the preconditions guarantee that the outcome is
            // less than 2^256, this is the final result. We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inverse;
            return result;
        }
    }

    /**
     * @notice Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        uint256 result = mulDiv(x, y, denominator);
        if (unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0) {
            result += 1;
        }
        return result;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * Inspired by Henry S. Warren, Jr.'s "Hacker's Delight" (Chapter 11).
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        // For our first guess, we get the biggest power of 2 which is smaller than the square root of the target.
        //
        // We know that the "msb" (most significant bit) of our target number `a` is a power of 2 such that we have
        // `msb(a) <= a < 2*msb(a)`. This value can be written `msb(a)=2**k` with `k=log2(a)`.
        //
        // This can be rewritten `2**log2(a) <= a < 2**(log2(a) + 1)`
        // → `sqrt(2**k) <= sqrt(a) < sqrt(2**(k+1))`
        // → `2**(k/2) <= sqrt(a) < 2**((k+1)/2) <= 2**(k/2 + 1)`
        //
        // Consequently, `2**(log2(a) / 2)` is a good first approximation of `sqrt(a)` with at least 1 correct bit.
        uint256 result = 1 << (log2(a) >> 1);

        // At this point `result` is an estimation with one bit of precision. We know the true value is a uint128,
        // since it is the square root of a uint256. Newton's method converges quadratically (precision doubles at
        // every iteration). We thus need at most 7 iteration to turn our partial result with one bit of precision
        // into the expected uint128 result.
        unchecked {
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            result = (result + a / result) >> 1;
            return min(result, a / result);
        }
    }

    /**
     * @notice Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + (unsignedRoundsUp(rounding) && result * result < a ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 128;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 64;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 32;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 16;
            }
            if (value >> 8 > 0) {
                value >>= 8;
                result += 8;
            }
            if (value >> 4 > 0) {
                value >>= 4;
                result += 4;
            }
            if (value >> 2 > 0) {
                value >>= 2;
                result += 2;
            }
            if (value >> 1 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + (unsignedRoundsUp(rounding) && 1 << result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + (unsignedRoundsUp(rounding) && 10 ** result < value ? 1 : 0);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >> 128 > 0) {
                value >>= 128;
                result += 16;
            }
            if (value >> 64 > 0) {
                value >>= 64;
                result += 8;
            }
            if (value >> 32 > 0) {
                value >>= 32;
                result += 4;
            }
            if (value >> 16 > 0) {
                value >>= 16;
                result += 2;
            }
            if (value >> 8 > 0) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + (unsignedRoundsUp(rounding) && 1 << (result << 3) < value ? 1 : 0);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/math/SignedMath.sol)

/**
 * @dev Standard signed math utilities missing in the Solidity language.
 */
library SignedMath {
    /**
     * @dev Returns the largest of two signed numbers.
     */
    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    /**
     * @dev Returns the smallest of two signed numbers.
     */
    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    /**
     * @dev Returns the average of two signed numbers without overflow.
     * The result is rounded towards zero.
     */
    function average(int256 a, int256 b) internal pure returns (int256) {
        // Formula from the book "Hacker's Delight"
        int256 x = (a & b) + ((a ^ b) >> 1);
        return x + (int256(uint256(x) >> 255) & (a ^ b));
    }

    /**
     * @dev Returns the absolute unsigned value of a signed value.
     */
    function abs(int256 n) internal pure returns (uint256) {
        unchecked {
            // must be unchecked in order to support `n = type(int256).min`
            return uint256(n >= 0 ? n : -n);
        }
    }
}

/**
 * @dev String operations.
 */
library Strings {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";
    uint8 private constant ADDRESS_LENGTH = 20;

    /**
     * @dev The `value` string doesn't fit in the specified `length`.
     */
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    /**
     * @dev Converts a `uint256` to its ASCII `string` decimal representation.
     */
    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            uint256 length = Math.log10(value) + 1;
            string memory buffer = new string(length);
            uint256 ptr;
            /// @solidity memory-safe-assembly
            assembly {
                ptr := add(buffer, add(32, length))
            }
            while (true) {
                ptr--;
                /// @solidity memory-safe-assembly
                assembly {
                    mstore8(ptr, byte(mod(value, 10), HEX_DIGITS))
                }
                value /= 10;
                if (value == 0) break;
            }
            return buffer;
        }
    }

    /**
     * @dev Converts a `int256` to its ASCII `string` decimal representation.
     */
    function toStringSigned(int256 value) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "", toString(SignedMath.abs(value)));
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation.
     */
    function toHexString(uint256 value) internal pure returns (string memory) {
        unchecked {
            return toHexString(value, Math.log256(value) + 1);
        }
    }

    /**
     * @dev Converts a `uint256` to its ASCII `string` hexadecimal representation with fixed length.
     */
    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        uint256 localValue = value;
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        if (localValue != 0) {
            revert StringsInsufficientHexLength(value, length);
        }
        return string(buffer);
    }

    /**
     * @dev Converts an `address` with fixed length of 20 bytes to its not checksummed ASCII `string` hexadecimal
     * representation.
     */
    function toHexString(address addr) internal pure returns (string memory) {
        return toHexString(uint256(uint160(addr)), ADDRESS_LENGTH);
    }

    /**
     * @dev Returns true if the two strings are equal.
     */
    function equal(string memory a, string memory b) internal pure returns (bool) {
        return bytes(a).length == bytes(b).length && keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (proxy/utils/Initializable.sol)

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```solidity
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 *
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Storage of the initializable contract.
     *
     * It's implemented on a custom ERC-7201 namespace to reduce the risk of storage collisions
     * when using with upgradeable contracts.
     *
     * @custom:storage-location erc7201:openzeppelin.storage.Initializable
     */
    struct InitializableStorage {
        /**
         * @dev Indicates that the contract has been initialized.
         */
        uint64 _initialized;
        /**
         * @dev Indicates that the contract is in the process of being initialized.
         */
        bool _initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /**
     * @dev The contract is already initialized.
     */
    error InvalidInitialization();

    /**
     * @dev The contract is not initializing.
     */
    error NotInitializing();

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint64 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts.
     *
     * Similar to `reinitializer(1)`, except that in the context of a constructor an `initializer` may be invoked any
     * number of times. This behavior in the constructor can be useful during testing and is not expected to be used in
     * production.
     *
     * Emits an {Initialized} event.
     */
    modifier initializer() {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        // Cache values to avoid duplicated sloads
        bool isTopLevelCall = !$._initializing;
        uint64 initialized = $._initialized;

        // Allowed calls:
        // - initialSetup: the contract is not in the initializing state and no previous version was
        //                 initialized
        // - construction: the contract is initialized at version 1 (no reininitialization) and the
        //                 current contract is just being deployed
        bool initialSetup = initialized == 0 && isTopLevelCall;
        bool construction = initialized == 1 && address(this).code.length == 0;

        if (!initialSetup && !construction) {
            revert InvalidInitialization();
        }
        $._initialized = 1;
        if (isTopLevelCall) {
            $._initializing = true;
        }
        _;
        if (isTopLevelCall) {
            $._initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * A reinitializer may be used after the original initialization step. This is essential to configure modules that
     * are added through upgrades and that require initialization.
     *
     * When `version` is 1, this modifier is similar to `initializer`, except that functions marked with `reinitializer`
     * cannot be nested. If one is invoked in the context of another, execution will revert.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     *
     * WARNING: Setting the version to 2**64 - 1 will prevent any future reinitialization.
     *
     * Emits an {Initialized} event.
     */
    modifier reinitializer(uint64 version) {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing || $._initialized >= version) {
            revert InvalidInitialization();
        }
        $._initialized = version;
        $._initializing = true;
        _;
        $._initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        _checkInitializing();
        _;
    }

    /**
     * @dev Reverts if the contract is not in an initializing state. See {onlyInitializing}.
     */
    function _checkInitializing() internal view virtual {
        if (!_isInitializing()) {
            revert NotInitializing();
        }
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     *
     * Emits an {Initialized} event the first time it is successfully executed.
     */
    function _disableInitializers() internal virtual {
        // solhint-disable-next-line var-name-mixedcase
        InitializableStorage storage $ = _getInitializableStorage();

        if ($._initializing) {
            revert InvalidInitialization();
        }
        if ($._initialized != type(uint64).max) {
            $._initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    /**
     * @dev Returns the highest version that has been initialized. See {reinitializer}.
     */
    function _getInitializedVersion() internal view returns (uint64) {
        return _getInitializableStorage()._initialized;
    }

    /**
     * @dev Returns `true` if the contract is currently initializing. See {onlyInitializing}.
     */
    function _isInitializing() internal view returns (bool) {
        return _getInitializableStorage()._initializing;
    }

    /**
     * @dev Returns a pointer to the storage namespace.
     */
    // solhint-disable-next-line var-name-mixedcase
    function _getInitializableStorage() private pure returns (InitializableStorage storage $) {
        assembly {
            $.slot := INITIALIZABLE_STORAGE
        }
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (access/AccessControl.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Context.sol)

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/introspection/ERC165.sol)

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 */
abstract contract ERC165Upgradeable is Initializable, IERC165 {
    function __ERC165_init() internal onlyInitializing {
    }

    function __ERC165_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

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
abstract contract AccessControlUpgradeable is Initializable, ContextUpgradeable, IAccessControl, ERC165Upgradeable {
    struct RoleData {
        mapping(address account => bool) hasRole;
        bytes32 adminRole;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @custom:storage-location erc7201:openzeppelin.storage.AccessControl
    struct AccessControlStorage {
        mapping(bytes32 role => RoleData) _roles;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.AccessControl")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AccessControlStorageLocation = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    function _getAccessControlStorage() private pure returns (AccessControlStorage storage $) {
        assembly {
            $.slot := AccessControlStorageLocation
        }
    }

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    function __AccessControl_init() internal onlyInitializing {
    }

    function __AccessControl_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAccessControl).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @dev Returns `true` if `account` has been granted `role`.
     */
    function hasRole(bytes32 role, address account) public view virtual returns (bool) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        return $._roles[role].hasRole[account];
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
        AccessControlStorage storage $ = _getAccessControlStorage();
        return $._roles[role].adminRole;
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
        AccessControlStorage storage $ = _getAccessControlStorage();
        bytes32 previousAdminRole = getRoleAdmin(role);
        $._roles[role].adminRole = adminRole;
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
        AccessControlStorage storage $ = _getAccessControlStorage();
        if (!hasRole(role, account)) {
            $._roles[role].hasRole[account] = true;
            emit RoleGranted(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Attempts to revoke `role` to `account` and returns a boolean indicating if `role` was revoked.
     *
     * Internal function without access restriction.
     *
     * May emit a {RoleRevoked} event.
     */
    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        AccessControlStorage storage $ = _getAccessControlStorage();
        if (hasRole(role, account)) {
            $._roles[role].hasRole[account] = false;
            emit RoleRevoked(role, account, _msgSender());
            return true;
        } else {
            return false;
        }
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/ReentrancyGuard.sol)

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    /// @custom:storage-location erc7201:openzeppelin.storage.ReentrancyGuard
    struct ReentrancyGuardStorage {
        uint256 _status;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ReentrancyGuard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ReentrancyGuardStorageLocation = 0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function _getReentrancyGuardStorage() private pure returns (ReentrancyGuardStorage storage $) {
        assembly {
            $.slot := ReentrancyGuardStorageLocation
        }
    }

    /**
     * @dev Unauthorized reentrant call.
     */
    error ReentrancyGuardReentrantCall();

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // On the first call to nonReentrant, _status will be NOT_ENTERED
        if ($._status == ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }

        // Any calls to nonReentrant after this point will fail
        $._status = ENTERED;
    }

    function _nonReentrantAfter() private {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        $._status = NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        ReentrancyGuardStorage storage $ = _getReentrancyGuardStorage();
        return $._status == ENTERED;
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (proxy/utils/UUPSUpgradeable.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/draft-IERC1822.sol)

/**
 * @dev ERC1822: Universal Upgradeable Proxy Standard (UUPS) documents a method for upgradeability through a simplified
 * proxy whose upgrades are fully controlled by the current implementation.
 */
interface IERC1822Proxiable {
    /**
     * @dev Returns the storage slot that the proxiable contract assumes is being used to store the implementation
     * address.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy.
     */
    function proxiableUUID() external view returns (bytes32);
}

// OpenZeppelin Contracts (last updated v5.0.0) (proxy/ERC1967/ERC1967Utils.sol)

// OpenZeppelin Contracts (last updated v5.0.0) (proxy/beacon/IBeacon.sol)

/**
 * @dev This is the interface that {BeaconProxy} expects of its beacon.
 */
interface IBeacon {
    /**
     * @dev Must return an address that can be used as a delegate call target.
     *
     * {UpgradeableBeacon} will check that this address is a contract.
     */
    function implementation() external view returns (address);
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error AddressInsufficientBalance(address account);

    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedInnerCall();

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.20/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        if (address(this).balance < amount) {
            revert AddressInsufficientBalance(address(this));
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert FailedInnerCall();
        }
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason or custom error, it is bubbled
     * up by this function (like regular Solidity function calls). However, if
     * the call reverted with no returned reason, this function reverts with a
     * {FailedInnerCall} error.
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert AddressInsufficientBalance(address(this));
        }
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and reverts if the target
     * was not a contract or bubbling up the revert reason (falling back to {FailedInnerCall}) in case of an
     * unsuccessful call.
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata
    ) internal view returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            // only check if target is a contract if the call was successful and the return data is empty
            // otherwise we already know that it was a contract
            if (returndata.length == 0 && target.code.length == 0) {
                revert AddressEmptyCode(target);
            }
            return returndata;
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and reverts if it wasn't, either by bubbling the
     * revert reason or with a default {FailedInnerCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {FailedInnerCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert FailedInnerCall();
        }
    }
}

// OpenZeppelin Contracts (last updated v5.0.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        /// @solidity memory-safe-assembly
        assembly {
            r.slot := store.slot
        }
    }
}

/**
 * @dev This abstract contract provides getters and event emitting update functions for
 * https://eips.ethereum.org/EIPS/eip-1967[EIP1967] slots.
 */
library ERC1967Utils {
    // We re-declare ERC-1967 events here because they can't be used directly from IERC1967.
    // This will be fixed in Solidity 0.8.21. At that point we should remove these events.
    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Emitted when the admin account has changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Emitted when the beacon is changed.
     */
    event BeaconUpgraded(address indexed beacon);

    /**
     * @dev Storage slot with the address of the current implementation.
     * This is the keccak-256 hash of "eip1967.proxy.implementation" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /**
     * @dev The `implementation` of the proxy is invalid.
     */
    error ERC1967InvalidImplementation(address implementation);

    /**
     * @dev The `admin` of the proxy is invalid.
     */
    error ERC1967InvalidAdmin(address admin);

    /**
     * @dev The `beacon` of the proxy is invalid.
     */
    error ERC1967InvalidBeacon(address beacon);

    /**
     * @dev An upgrade function sees `msg.value > 0` that may be lost.
     */
    error ERC1967NonPayable();

    /**
     * @dev Returns the current implementation address.
     */
    function getImplementation() internal view returns (address) {
        return StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 implementation slot.
     */
    function _setImplementation(address newImplementation) private {
        if (newImplementation.code.length == 0) {
            revert ERC1967InvalidImplementation(newImplementation);
        }
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = newImplementation;
    }

    /**
     * @dev Performs implementation upgrade with additional setup call if data is nonempty.
     * This function is payable only if the setup call is performed, otherwise `msg.value` is rejected
     * to avoid stuck value in the contract.
     *
     * Emits an {IERC1967-Upgraded} event.
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) internal {
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);

        if (data.length > 0) {
            Address.functionDelegateCall(newImplementation, data);
        } else {
            _checkNonPayable();
        }
    }

    /**
     * @dev Storage slot with the admin of the contract.
     * This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /**
     * @dev Returns the current admin.
     *
     * TIP: To get this value clients can read directly from the storage slot shown below (specified by EIP1967) using
     * the https://eth.wiki/json-rpc/API#eth_getstorageat[`eth_getStorageAt`] RPC call.
     * `0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`
     */
    function getAdmin() internal view returns (address) {
        return StorageSlot.getAddressSlot(ADMIN_SLOT).value;
    }

    /**
     * @dev Stores a new address in the EIP1967 admin slot.
     */
    function _setAdmin(address newAdmin) private {
        if (newAdmin == address(0)) {
            revert ERC1967InvalidAdmin(address(0));
        }
        StorageSlot.getAddressSlot(ADMIN_SLOT).value = newAdmin;
    }

    /**
     * @dev Changes the admin of the proxy.
     *
     * Emits an {IERC1967-AdminChanged} event.
     */
    function changeAdmin(address newAdmin) internal {
        emit AdminChanged(getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /**
     * @dev The storage slot of the UpgradeableBeacon contract which defines the implementation for this proxy.
     * This is the keccak-256 hash of "eip1967.proxy.beacon" subtracted by 1.
     */
    // solhint-disable-next-line private-vars-leading-underscore
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /**
     * @dev Returns the current beacon.
     */
    function getBeacon() internal view returns (address) {
        return StorageSlot.getAddressSlot(BEACON_SLOT).value;
    }

    /**
     * @dev Stores a new beacon in the EIP1967 beacon slot.
     */
    function _setBeacon(address newBeacon) private {
        if (newBeacon.code.length == 0) {
            revert ERC1967InvalidBeacon(newBeacon);
        }

        StorageSlot.getAddressSlot(BEACON_SLOT).value = newBeacon;

        address beaconImplementation = IBeacon(newBeacon).implementation();
        if (beaconImplementation.code.length == 0) {
            revert ERC1967InvalidImplementation(beaconImplementation);
        }
    }

    /**
     * @dev Change the beacon and trigger a setup call if data is nonempty.
     * This function is payable only if the setup call is performed, otherwise `msg.value` is rejected
     * to avoid stuck value in the contract.
     *
     * Emits an {IERC1967-BeaconUpgraded} event.
     *
     * CAUTION: Invoking this function has no effect on an instance of {BeaconProxy} since v5, since
     * it uses an immutable beacon without looking at the value of the ERC-1967 beacon slot for
     * efficiency.
     */
    function upgradeBeaconToAndCall(address newBeacon, bytes memory data) internal {
        _setBeacon(newBeacon);
        emit BeaconUpgraded(newBeacon);

        if (data.length > 0) {
            Address.functionDelegateCall(IBeacon(newBeacon).implementation(), data);
        } else {
            _checkNonPayable();
        }
    }

    /**
     * @dev Reverts if `msg.value` is not zero. It can be used to avoid `msg.value` stuck in the contract
     * if an upgrade doesn't perform an initialization call.
     */
    function _checkNonPayable() private {
        if (msg.value > 0) {
            revert ERC1967NonPayable();
        }
    }
}

/**
 * @dev An upgradeability mechanism designed for UUPS proxies. The functions included here can perform an upgrade of an
 * {ERC1967Proxy}, when this contract is set as the implementation behind such a proxy.
 *
 * A security mechanism ensures that an upgrade does not turn off upgradeability accidentally, although this risk is
 * reinstated if the upgrade retains upgradeability but removes the security mechanism, e.g. by replacing
 * `UUPSUpgradeable` with a custom implementation of upgrades.
 *
 * The {_authorizeUpgrade} function must be overridden to include access restriction to the upgrade mechanism.
 */
abstract contract UUPSUpgradeable is Initializable, IERC1822Proxiable {
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address private immutable __self = address(this);

    /**
     * @dev The version of the upgrade interface of the contract. If this getter is missing, both `upgradeTo(address)`
     * and `upgradeToAndCall(address,bytes)` are present, and `upgradeTo` must be used if no function should be called,
     * while `upgradeToAndCall` will invoke the `receive` function if the second argument is the empty byte string.
     * If the getter returns `"5.0.0"`, only `upgradeToAndCall(address,bytes)` is present, and the second argument must
     * be the empty byte string if no function should be called, making it impossible to invoke the `receive` function
     * during an upgrade.
     */
    string public constant UPGRADE_INTERFACE_VERSION = "5.0.0";

    /**
     * @dev The call is from an unauthorized context.
     */
    error UUPSUnauthorizedCallContext();

    /**
     * @dev The storage `slot` is unsupported as a UUID.
     */
    error UUPSUnsupportedProxiableUUID(bytes32 slot);

    /**
     * @dev Check that the execution is being performed through a delegatecall call and that the execution context is
     * a proxy contract with an implementation (as defined in ERC1967) pointing to self. This should only be the case
     * for UUPS and transparent proxies that are using the current contract as their implementation. Execution of a
     * function through ERC1167 minimal proxies (clones) would not normally pass this test, but is not guaranteed to
     * fail.
     */
    modifier onlyProxy() {
        _checkProxy();
        _;
    }

    /**
     * @dev Check that the execution is not being performed through a delegate call. This allows a function to be
     * callable on the implementing contract but not through proxies.
     */
    modifier notDelegated() {
        _checkNotDelegated();
        _;
    }

    function __UUPSUpgradeable_init() internal onlyInitializing {
    }

    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {
    }
    /**
     * @dev Implementation of the ERC1822 {proxiableUUID} function. This returns the storage slot used by the
     * implementation. It is used to validate the implementation's compatibility when performing an upgrade.
     *
     * IMPORTANT: A proxy pointing at a proxiable contract should not be considered proxiable itself, because this risks
     * bricking a proxy that upgrades to it, by delegating to itself until out of gas. Thus it is critical that this
     * function revert if invoked through a proxy. This is guaranteed by the `notDelegated` modifier.
     */
    function proxiableUUID() external view virtual notDelegated returns (bytes32) {
        return ERC1967Utils.IMPLEMENTATION_SLOT;
    }

    /**
     * @dev Upgrade the implementation of the proxy to `newImplementation`, and subsequently execute the function call
     * encoded in `data`.
     *
     * Calls {_authorizeUpgrade}.
     *
     * Emits an {Upgraded} event.
     *
     * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
     */
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {
        _authorizeUpgrade(newImplementation);
        _upgradeToAndCallUUPS(newImplementation, data);
    }

    /**
     * @dev Reverts if the execution is not performed via delegatecall or the execution
     * context is not of a proxy with an ERC1967-compliant implementation pointing to self.
     * See {_onlyProxy}.
     */
    function _checkProxy() internal view virtual {
        if (
            address(this) == __self || // Must be called through delegatecall
            ERC1967Utils.getImplementation() != __self // Must be called through an active proxy
        ) {
            revert UUPSUnauthorizedCallContext();
        }
    }

    /**
     * @dev Reverts if the execution is performed via delegatecall.
     * See {notDelegated}.
     */
    function _checkNotDelegated() internal view virtual {
        if (address(this) != __self) {
            // Must not be called through delegatecall
            revert UUPSUnauthorizedCallContext();
        }
    }

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeToAndCall}.
     *
     * Normally, this function will use an xref:access.adoc[access control] modifier such as {Ownable-onlyOwner}.
     *
     * ```solidity
     * function _authorizeUpgrade(address) internal onlyOwner {}
     * ```
     */
    function _authorizeUpgrade(address newImplementation) internal virtual;

    /**
     * @dev Performs an implementation upgrade with a security check for UUPS proxies, and additional setup call.
     *
     * As a security check, {proxiableUUID} is invoked in the new implementation, and the return value
     * is expected to be the implementation slot in ERC1967.
     *
     * Emits an {IERC1967-Upgraded} event.
     */
    function _upgradeToAndCallUUPS(address newImplementation, bytes memory data) private {
        try IERC1822Proxiable(newImplementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != ERC1967Utils.IMPLEMENTATION_SLOT) {
                revert UUPSUnsupportedProxiableUUID(slot);
            }
            ERC1967Utils.upgradeToAndCall(newImplementation, data);
        } catch {
            // The implementation is not UUPS
            revert ERC1967Utils.ERC1967InvalidImplementation(newImplementation);
        }
    }
}

enum Tiers {ZERO, ONE, TWO, THREE, FOUR, FIVE, SIX}

struct Ticket {
    uint256 ticketType;
    uint256 from;
    uint256 to;
    uint256 drawDate;
    address ticketOwner;
}

struct Tax {
    uint256 buy;
    uint256 grandPrize;
    uint256 otherPrize;
    uint256 precision;
}

struct TierPrizes {
    uint256 tier0;
    uint256 tier1;
    uint256 tier2;
    uint256 tier3;
    uint256 tier4;
    uint256 tier5;
    uint256 tier6;
}

struct DrawResult {
    uint256 id;
    uint256 prizePoolSnapshot;
    uint256 vendorTotalSnapshot;
    uint256 totalRewardSnapshot;
    uint256 totalPlatformTaxSnapshot;
    LotteryNumbers game;
}

struct LotteryNumbers {
    uint8 ball1; 
    uint8 ball2; 
    uint8 ball3; 
    uint8 ball4; 
    uint8 ball5; 
    uint8 ball6;
}

struct Prize {
    /** @dev this is the total of all unclaimed rewards
     * accross all reward pool from all past draws
     */
    uint256 total;
    /**
     * @dev this is where the rewardPool is recorded
     * 
     * reward pool is separated by data in unix timestamp
     * format
     */
    mapping(uint256=>uint256) pool;
}

/**
 * @dev this is used as a param type
 * in an array form during claiming
 * of winning rewards
 * 
 * ticket id, game id, tier, hashedMessage,
 * signature and owner are used in the 
 * verification process that happens during 
 * claiming to prevent other users from 
 * claiming another user's winning 
 * 
 * the verification uses openzeppelin's ECDSA to retrive 
 * the signer and check if the sgner has the VERIFIER_ROLE
 * and if the hashed message provided is equal to the
 * generated hashed message * for it to be considered 
 * valid
 */
struct ClaimInfo {
    uint256 ticketId;
    uint256 gameId;
    uint256 tier;
    bytes32 hashedMessage;
    bytes signature;
}

/**
 * @dev this is used as a type
 * for assigning the amount of winners
 * for every tier in a draw
 */
struct WinnersPerTier {
    uint256 tier1;
    uint256 tier2;
    uint256 tier3;
    uint256 tier4;
    uint256 tier5;
    uint256 tier6;
}

/**
 * @dev this is used as a type during calculations of
 * prize and pool distribution during draw 
 */
struct TierValue {
    uint256 tier1;
    uint256 tier2;
    uint256 tier3;
    uint256 tier4;
    uint256 tier5;
    uint256 tier6;
}

struct DateTimeType {
    uint256 month;
    uint256 day;
    uint256 year;
    uint256 hour;
    uint256 minute;
    uint256 second;
}

/**
 * @dev this is used as a param type
 * to make it easier to input the draw
 * date using the month, day, and year
 * instead of using the unix timestamp
 * format when interacting with the contract
 * 
 * this also reduces the input error that
 * could happen when using unix timestamp as
 * input
 */
struct DateType {
    uint256 month;
    uint256 day;
    uint256 year;
}

struct TimeType {
    uint256 hour;
    uint256 minute;
    uint256 second;
}

enum DayOfWeek {DONOTUSETHIS, MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY, SUNDAY}

struct VendorInfo {
    address referrer;
    address receiver;
    uint256 isVendor;
    uint256 timer;
}

struct GameOwnership {
    address gameOwner;
    uint256 amount;
} 

// used inside one of the buyGamesFrom function to avoid stack too deep error
struct BuyGamesFromInfo {
    address vendor;
    uint256 ticketType;
    uint256 drawDate;
    uint256 price;
    uint256 gameIdEnd;
    uint256 ticketId;
}

struct BuyGamesInfo {
    address buyer;
    uint256 ticketType;
    uint256 drawDate;
}

/**
 * ### #     # ######  ####### ######  #######    #    #     # ####### ### 
 *  #  ##   ## #     # #     # #     #    #      # #   ##    #    #    ### 
 *  #  # # # # #     # #     # #     #    #     #   #  # #   #    #    ### 
 *  #  #  #  # ######  #     # ######     #    #     # #  #  #    #     #  
 *  #  #     # #       #     # #   #      #    ####### #   # #    #        
 *  #  #     # #       #     # #    #     #    #     # #    ##    #    ### 
 * ### #     # #       ####### #     #    #    #     # #     #    #    ###
 * 
 * DO NOT ADD ANYTING IN BETWEEN OR RENAME ANY STATE VARIABLE HERE FOR UPGRADES
 * 
 * ONLY ADD NEW STATES BELOW THE OLD STATES TO PREVENT OLD STATES FROM BEING
 * OVERWRITTEN AND CORRUPTED
 * 
 * THIS IS THE STRUCT THAT USES ERC7201 (NAMESPACED STORAGE LAYOUT) TO PREVENT
 * STORAGE COLLISSION ON UPGRADEABLE CONTRACTS
 * 
 * ERC7201 IS ONLY AVAILABLE ON SOLIDITY VERSION 0.8.20 AND ABOVE
 */

/// @custom:storage-location erc7201:pegaball.storage.Wallet
struct WalletStorage {
    address PLATFORM_WALLET;
}

/// @custom:storage-location erc7201:pegaball.storage.Pool
struct PoolStorage {
    uint256 platformPool;
    uint256 vendorPool;
    Prize rewardPool;
}

/// @custom:storage-location erc7201:pegaball.storage.Information
struct InformationStorage {
    uint256 gamePrice;
    uint256 totalGames;
    uint256 drawCount;
    uint256 ticketCount;
    uint256 TWENTY_MILLION;
    uint256 ONE_MILLION;
}

/// @custom:storage-location erc7201:pegaball.storage.Ticket
struct TicketStorage {
    mapping(uint256 => Ticket) tickets;
    mapping(uint256 => uint256) isClaimed;
    mapping(uint256 => DrawResult) drawResult;
    mapping(uint256 => TierPrizes) tierPrizes;
    mapping(uint256 => WinnersPerTier) winnersPerTier;
    mapping (uint256 => uint256) totalGamesByDrawDate;
    Tax taxFees;
    mapping(address => VendorInfo) vendor;
}

/// @custom:storage-location erc7201:pegaball.storage.Lockable
struct LockableStorage {
    uint256 buyLockPeriod;
    uint256 claimLockPeriod;
}

/// @custom:storage-location erc7201:pegaball.storage.Whitelist
struct WhitelistStorage {
    bool whitelistMode;
    mapping(address=>bool) isWhitelisted;
}

error TicketIsExpired();

error IncorrectPaymentAmount();

error NotAWinner();

error AlreadyDrawn();
error AlreadyClaimed(uint256 gameId);

error DrawHasNotHappenedYet();
error DrawAndCalculationsOngoing();

error InvalidFeeError(string);
error InvalidDrawDate(string);
error InvalidResultAmount();
error InvalidTicketOwner();
error InvalidPrizeTierInformation();
error CanNotBeZeroAddress();
error UnauthorizedAccess();

error NotYetExpired();

error BuyingIsPaused();
error DrawDateNotMatching();
error InsufficientBalance();

error ClaimerCanNotBeVendor();
error VendorAlreadyRegistered();
error NotAVendor();
error IsAVendor();
error NotInTheWhitelist();

abstract contract PegaBallBaseUpgradeable is Initializable, ContextUpgradeable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {

    // implementation version
    string public constant version = "1.0.0";

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @dev powerball draw time equivalent in UTC ahead of 1 minute
    /// draw time in EST is 10:59:00 PM which is 2:59:00 AM UTC next day
    uint256 internal constant DRAW_HOUR_IN_UTC = 3;
    uint256 internal constant DRAW_MINUTE_IN_UTC = 0;
    uint256 internal constant DRAW_SECOND_IN_UTC = 0;

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Wallet")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant WALLET_STORAGE_LOCATION = 0xeb6e7afeca381420e5b624b68b7cf9e10d7d7277ec5aefcf6d36ea9aec68de00;

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Pool")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant POOL_STORAGE_LOCATION = 0x11c8c3500747212208687d248ead8d1b4ea12bd66d695080a931f4a2e7883400;

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Information")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant INFORMATION_STORAGE_LOCATION = 0x7016e2633248f863d108ef5372bd8d17605b69dcc639e67e4a43f2ecf3457400;

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Ticket")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant TICKET_STORAGE_LOCATION = 0xe6e6114e33b277b3c7b0492f355795961094c9963b4f185b18ae8632277ebf00;

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Whitelist")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant WHITELIST_STORAGE_LOCATION = 0xdce41456af7a802f1f335ce52e359560a77c4a57f636c1a85aa2f445e3ff3500;
    
    // _get*Storage() functions are functions under ERC7201 used to fetch storage from a specific storage location

    function _getWalletStorage() internal pure returns (WalletStorage storage $) {
        assembly {
            $.slot := WALLET_STORAGE_LOCATION
        }
    }

    function _getPoolStorage() internal pure returns (PoolStorage storage $) {
        assembly {
            $.slot := POOL_STORAGE_LOCATION
        }
    }

    function _getInformationStorage() internal pure returns (InformationStorage storage $) {
        assembly {
            $.slot := INFORMATION_STORAGE_LOCATION
        }
    }

    function _getTicketStorage() internal pure returns (TicketStorage storage $) {
        assembly {
            $.slot := TICKET_STORAGE_LOCATION
        }
    }

    function _getWhitelistStorage() internal pure returns (WhitelistStorage storage $) {
        assembly {
            $.slot := WHITELIST_STORAGE_LOCATION
        }
    }

    /**
     * @custom:function-name __PegaBallBase_init
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev this function is used to initialize the contract's necessary states like 
     * 
     * the platform wallet which is the admin used to trigger admin functions 
     * 
     * the draw wallet used to trigger the draw
     * 
     * the game price which also sets the caps in eth equivalent 20M USD and 1M USD
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallBase_init(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) internal onlyInitializing {
        
        __PegaBallBase_init_unchained(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);

    }

    /**
     * @custom:function-name __PegaBallBase_init_unchained
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallBase_init_unchained(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) private onlyInitializing {

        __AccessControl_init();
        __UUPSUpgradeable_init();

        __init_wallets(_PLATFORM_WALLET, _DRAW_WALLET);
        __init_tickets(_tax);
        __init_information(_gamePrice);

    }

    /**
     * @custom:function-name __init_wallets
     *  
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * 
     * @dev this function is used in the __init_* function to initialize the wallets
     */
    function __init_wallets(address _PLATFORM_WALLET, address _DRAW_WALLET) private {
        
        address platformWallet = _PLATFORM_WALLET;
        address drawWallet = _DRAW_WALLET;

        if(platformWallet == address(0) || 
        drawWallet == address(0)) revert CanNotBeZeroAddress();

        WalletStorage storage $ = _getWalletStorage();

        $.PLATFORM_WALLET = platformWallet;
    

        _grantRole(UPGRADER_ROLE, platformWallet);
        _grantRole(DEFAULT_ADMIN_ROLE, platformWallet);
        _grantRole(keccak256("PRICE_CHANGER_ROLE"), platformWallet);
        _grantRole(keccak256("DRAW_ROLE"), platformWallet);
        _grantRole(keccak256("DRAW_ROLE"), drawWallet);
        _grantRole(keccak256("VERIFIER_ROLE"), platformWallet);
        _grantRole(keccak256("VERIFIER_ROLE"), drawWallet);

    }

    /**
     * @custom:function-name __init_tickets
     * 
     * @param _tax taxes in percentage along with the precision
     * 
     * @dev this function is used in the __init_* function to initialize the taxes
     *
     */
    function __init_tickets(Tax calldata _tax) private {
        TicketStorage storage $ = _getTicketStorage();
        $.taxFees = _tax;
    }

    /**
     * @custom:function-name __init_information
     * 
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev this function is used to initialize the value of game price and
     * the value of the 20M and 1M cap in ETH during deployment
     */
    function __init_information(uint256 _gamePrice) private {
        InformationStorage storage $ = _getInformationStorage();

        $.gamePrice = _gamePrice;

        uint256 _twentyMillion = _gamePrice * 10_000_000;
        uint256 _oneMillion =  _twentyMillion / 20;

        /**
         * @dev This TWENTY_MILLION is used to limit the amount of 
         * ETH to be deducted from the jackpot left for the next
         * draw's prize pool to TWENTY MILLION USD in ETH 
         * 
         * this is 10% of the jackpot capped at 20 MILLION
         */         
        $.TWENTY_MILLION = _twentyMillion;

        /**
         * @dev This ONE_MILLION is used to limit the amount of 
         * ETH to be deducted from the jackpot amount claimable 
         * by the winner as a third party vendor's cut when 
         * the winning game was bought from them 
         * to ONE MILLION USD in ETH
         * 
         * this is 10% of the claimable jackpot capped at 1 MILLION 
         */  
        $.ONE_MILLION = _oneMillion;
    }

}

abstract contract LockableUpgradeable is PegaBallBaseUpgradeable {

    // keccak256(abi.encode(uint256(keccak256("pegaball.storage.Lockable")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LOCKABLE_STORAGE_LOCATION = 0x5e198fdb290fa76a75ef97b18770380f9a9e1e8937370cd15de0a3dc66144000;

    error InteractionNotAllowedWhenLocked();

    event Locked(uint256 indexed timestamp, address indexed caller);
    event UnLocked(uint256 indexed timestamp);

    // _get*Storage() functions are functions under ERC7201 used to fetch storage from a specific storage location

    function _getLockableStorage() internal pure returns (LockableStorage storage $) {
        assembly {
            $.slot := LOCKABLE_STORAGE_LOCATION
        }
    }

    /**
     * @custom:function-name __Locakable_init
     *  
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     * 
     * this is currently commented out since there are not contents inside
     */
    // function __Locakable_init() internal onlyInitializing {}

    /**
     * @custom:function-name __Locakable_init_unchained
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     * 
     * this is currently commented out since there are not contents inside
     */
    // function __Locakable_init_unchained() internal onlyInitializing {}

    /**
     * @custom:function-name lockBuying
     * 
     * @param _hours hours from now
     * @param _minutes minutes from now
     * @param _seconds seconds from now
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to lock the buying of tickets for a certain amount of time 
     */
    function lockBuying(uint256 _hours, uint256 _minutes, uint256 _seconds) external virtual onlyRole(keccak256("DRAW_ROLE")) {
        LockableStorage storage $ = _getLockableStorage();

        uint256 currentTime = block.timestamp;
        address caller = _msgSender();
        $.buyLockPeriod = currentTime + (_hours * 1 hours) + (_minutes * 1 minutes) + (_seconds * 1 seconds);
        emit Locked(currentTime, caller);
    }

    /**
     * @custom:function-name lockClaiming
     * 
     * @param _hours hours from now
     * @param _minutes minutes from now
     * @param _seconds seconds from now
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to lock the claiming of tickets for a certain amount of time 
     */
    function lockClaiming(uint256 _hours, uint256 _minutes, uint256 _seconds) external virtual onlyRole(keccak256("DRAW_ROLE")) {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        address caller = _msgSender();
        $.claimLockPeriod = currentTime + (_hours * 1 hours) + (_minutes * 1 minutes) + (_seconds * 1 seconds);
        emit Locked(currentTime, caller);
    }

    /**
     * @custom:function-name lockInteraction
     * 
     * @param _hours hours from now
     * @param _minutes minutes from now
     * @param _seconds seconds from now
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to lock the buy and claim for a certain amount of time 
     */
    function lockInteraction(uint256 _hours, uint256 _minutes, uint256 _seconds) external virtual onlyRole(keccak256("DRAW_ROLE")) {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        address caller = _msgSender();
        uint256 lockPeriod = currentTime + (_hours * 1 hours) + (_minutes * 1 minutes) + (_seconds * 1 seconds);
        $.claimLockPeriod = lockPeriod;
        $.buyLockPeriod = lockPeriod;
        emit Locked(currentTime, caller);
    }

    /**
     * @custom:function-name unLockClaiming
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to unlock in case of locking it for an incorrect
     * amount of time
     */
    function unLockClaiming() external virtual  onlyRole(DEFAULT_ADMIN_ROLE) {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        $.claimLockPeriod = 0;
        emit UnLocked(currentTime);
    }

    /**
     * @custom:function-name unLockInteraction
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to unlock in case of locking it for an incorrect
     * amount of time
     */
    function unLockInteraction() external virtual  onlyRole(DEFAULT_ADMIN_ROLE) {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        $.buyLockPeriod = 0;
        $.claimLockPeriod = 0;
        emit UnLocked(currentTime);
    }

    /**
     * @custom:function-name unLockBuying
     * 
     * @custom:access-restrictions Admin
     * 
     * @dev this function is used to unlock in case of locking it for an incorrect
     * amount of time
     */
    function unLockBuying() external virtual  onlyRole(DEFAULT_ADMIN_ROLE) {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        $.buyLockPeriod = 0;
        emit UnLocked(currentTime);
    }
    
    /**
     * @custom:modifier-name isBuyNotLocked
     * 
     * @dev this modifier is used in `buyTickets` to revert it if the ticket buying is locked
     * mostly likely 1 hour before the draw happen
     */
    modifier isBuyNotLocked {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        if(currentTime <= $.buyLockPeriod) revert InteractionNotAllowedWhenLocked();
        _;
    }

    /**
     * @custom:modifier-name isClaimNotLocked
     * 
     * @dev this modifier is used in `claims` to revert it if the ticket claiming is locked
     */
    modifier isClaimNotLocked {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        if(currentTime <= $.claimLockPeriod) revert InteractionNotAllowedWhenLocked();
        _;
    }

    /**
     * @custom:modifier-name isInteractionNotLocked
     * 
     * @dev this modifier is used to revert transaction if the ticket buying and claiming
     * are locked
     */
    modifier isInteractionNotLocked {
        LockableStorage storage $ = _getLockableStorage();
        uint256 currentTime = block.timestamp;
        if(currentTime <= $.buyLockPeriod || currentTime <= $.claimLockPeriod) revert InteractionNotAllowedWhenLocked();
        _;
    }
}

// ----------------------------------------------------------------------------
// BokkyPooBah's DateTime Library v1.01
//
// A gas-efficient Solidity date and time library
//
// https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary
//
// Tested date range 1970/01/01 to 2345/12/31
//
// Conventions:
// Unit      | Range         | Notes
// :-------- |:-------------:|:-----
// timestamp | >= 0          | Unix timestamp, number of seconds since 1970/01/01 00:00:00 UTC
// year      | 1970 ... 2345 |
// month     | 1 ... 12      |
// day       | 1 ... 31      |
// hour      | 0 ... 23      |
// minute    | 0 ... 59      |
// second    | 0 ... 59      |
// dayOfWeek | 1 ... 7       | 1 = Monday, ..., 7 = Sunday
//
//
// Enjoy. (c) BokkyPooBah / Bok Consulting Pty Ltd 2018-2019. The MIT Licence.
// ----------------------------------------------------------------------------

library BokkyPooBahsDateTimeLibrary {

    uint constant SECONDS_PER_DAY = 24 * 60 * 60;
    uint constant SECONDS_PER_HOUR = 60 * 60;
    uint constant SECONDS_PER_MINUTE = 60;
    int constant OFFSET19700101 = 2440588;

    uint constant DOW_MON = 1;
    uint constant DOW_TUE = 2;
    uint constant DOW_WED = 3;
    uint constant DOW_THU = 4;
    uint constant DOW_FRI = 5;
    uint constant DOW_SAT = 6;
    uint constant DOW_SUN = 7;

    // ------------------------------------------------------------------------
    // Calculate the number of days from 1970/01/01 to year/month/day using
    // the date conversion algorithm from
    //   https://aa.usno.navy.mil/faq/JD_formula.html
    // and subtracting the offset 2440588 so that 1970/01/01 is day 0
    //
    // days = day
    //      - 32075
    //      + 1461 * (year + 4800 + (month - 14) / 12) / 4
    //      + 367 * (month - 2 - (month - 14) / 12 * 12) / 12
    //      - 3 * ((year + 4900 + (month - 14) / 12) / 100) / 4
    //      - offset
    // ------------------------------------------------------------------------
    function _daysFromDate(uint year, uint month, uint day) internal pure returns (uint _days) {
        require(year >= 1970);
        int _year = int(year);
        int _month = int(month);
        int _day = int(day);

        int __days = _day
          - 32075
          + 1461 * (_year + 4800 + (_month - 14) / 12) / 4
          + 367 * (_month - 2 - (_month - 14) / 12 * 12) / 12
          - 3 * ((_year + 4900 + (_month - 14) / 12) / 100) / 4
          - OFFSET19700101;

        _days = uint(__days);
    }

    // ------------------------------------------------------------------------
    // Calculate year/month/day from the number of days since 1970/01/01 using
    // the date conversion algorithm from
    //   http://aa.usno.navy.mil/faq/docs/JD_Formula.php
    // and adding the offset 2440588 so that 1970/01/01 is day 0
    //
    // int L = days + 68569 + offset
    // int N = 4 * L / 146097
    // L = L - (146097 * N + 3) / 4
    // year = 4000 * (L + 1) / 1461001
    // L = L - 1461 * year / 4 + 31
    // month = 80 * L / 2447
    // dd = L - 2447 * month / 80
    // L = month / 11
    // month = month + 2 - 12 * L
    // year = 100 * (N - 49) + year + L
    // ------------------------------------------------------------------------
    function _daysToDate(uint _days) internal pure returns (uint year, uint month, uint day) {
        int __days = int(_days);

        int L = __days + 68569 + OFFSET19700101;
        int N = 4 * L / 146097;
        L = L - (146097 * N + 3) / 4;
        int _year = 4000 * (L + 1) / 1461001;
        L = L - 1461 * _year / 4 + 31;
        int _month = 80 * L / 2447;
        int _day = L - 2447 * _month / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint(_year);
        month = uint(_month);
        day = uint(_day);
    }

    function timestampFromDate(uint year, uint month, uint day) internal pure returns (uint timestamp) {
        timestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY;
    }
    function timestampFromDateTime(uint year, uint month, uint day, uint hour, uint minute, uint second) internal pure returns (uint timestamp) {
        timestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + hour * SECONDS_PER_HOUR + minute * SECONDS_PER_MINUTE + second;
    }
    function timestampToDate(uint timestamp) internal pure returns (uint year, uint month, uint day) {
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function timestampToDateTime(uint timestamp) internal pure returns (uint year, uint month, uint day, uint hour, uint minute, uint second) {
        (year, month, day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        uint secs = timestamp % SECONDS_PER_DAY;
        hour = secs / SECONDS_PER_HOUR;
        secs = secs % SECONDS_PER_HOUR;
        minute = secs / SECONDS_PER_MINUTE;
        second = secs % SECONDS_PER_MINUTE;
    }

    function isValidDate(uint year, uint month, uint day) internal pure returns (bool valid) {
        if (year >= 1970 && month > 0 && month <= 12) {
            uint daysInMonth = _getDaysInMonth(year, month);
            if (day > 0 && day <= daysInMonth) {
                valid = true;
            }
        }
    }
    function isValidDateTime(uint year, uint month, uint day, uint hour, uint minute, uint second) internal pure returns (bool valid) {
        if (isValidDate(year, month, day)) {
            if (hour < 24 && minute < 60 && second < 60) {
                valid = true;
            }
        }
    }
    function isLeapYear(uint timestamp) internal pure returns (bool leapYear) {
        (uint year,,) = _daysToDate(timestamp / SECONDS_PER_DAY);
        leapYear = _isLeapYear(year);
    }
    function _isLeapYear(uint year) internal pure returns (bool leapYear) {
        leapYear = ((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0);
    }
    function isWeekDay(uint timestamp) internal pure returns (bool weekDay) {
        weekDay = getDayOfWeek(timestamp) <= DOW_FRI;
    }
    function isWeekEnd(uint timestamp) internal pure returns (bool weekEnd) {
        weekEnd = getDayOfWeek(timestamp) >= DOW_SAT;
    }
    function getDaysInMonth(uint timestamp) internal pure returns (uint daysInMonth) {
        (uint year, uint month,) = _daysToDate(timestamp / SECONDS_PER_DAY);
        daysInMonth = _getDaysInMonth(year, month);
    }
    function _getDaysInMonth(uint year, uint month) internal pure returns (uint daysInMonth) {
        if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
            daysInMonth = 31;
        } else if (month != 2) {
            daysInMonth = 30;
        } else {
            daysInMonth = _isLeapYear(year) ? 29 : 28;
        }
    }
    // 1 = Monday, 7 = Sunday
    function getDayOfWeek(uint timestamp) internal pure returns (uint dayOfWeek) {
        uint _days = timestamp / SECONDS_PER_DAY;
        dayOfWeek = (_days + 3) % 7 + 1;
    }

    function getYear(uint timestamp) internal pure returns (uint year) {
        (year,,) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getMonth(uint timestamp) internal pure returns (uint month) {
        (,month,) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getDay(uint timestamp) internal pure returns (uint day) {
        (,,day) = _daysToDate(timestamp / SECONDS_PER_DAY);
    }
    function getHour(uint timestamp) internal pure returns (uint hour) {
        uint secs = timestamp % SECONDS_PER_DAY;
        hour = secs / SECONDS_PER_HOUR;
    }
    function getMinute(uint timestamp) internal pure returns (uint minute) {
        uint secs = timestamp % SECONDS_PER_HOUR;
        minute = secs / SECONDS_PER_MINUTE;
    }
    function getSecond(uint timestamp) internal pure returns (uint second) {
        second = timestamp % SECONDS_PER_MINUTE;
    }

    function addYears(uint timestamp, uint _years) internal pure returns (uint newTimestamp) {
        (uint year, uint month, uint day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        year += _years;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addMonths(uint timestamp, uint _months) internal pure returns (uint newTimestamp) {
        (uint year, uint month, uint day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        month += _months;
        year += (month - 1) / 12;
        month = (month - 1) % 12 + 1;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addDays(uint timestamp, uint _days) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _days * SECONDS_PER_DAY;
        require(newTimestamp >= timestamp);
    }
    function addHours(uint timestamp, uint _hours) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _hours * SECONDS_PER_HOUR;
        require(newTimestamp >= timestamp);
    }
    function addMinutes(uint timestamp, uint _minutes) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _minutes * SECONDS_PER_MINUTE;
        require(newTimestamp >= timestamp);
    }
    function addSeconds(uint timestamp, uint _seconds) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp + _seconds;
        require(newTimestamp >= timestamp);
    }

    function subYears(uint timestamp, uint _years) internal pure returns (uint newTimestamp) {
        (uint year, uint month, uint day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        year -= _years;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subMonths(uint timestamp, uint _months) internal pure returns (uint newTimestamp) {
        (uint year, uint month, uint day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        uint yearMonth = year * 12 + (month - 1) - _months;
        year = yearMonth / 12;
        month = yearMonth % 12 + 1;
        uint daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + timestamp % SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subDays(uint timestamp, uint _days) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _days * SECONDS_PER_DAY;
        require(newTimestamp <= timestamp);
    }
    function subHours(uint timestamp, uint _hours) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _hours * SECONDS_PER_HOUR;
        require(newTimestamp <= timestamp);
    }
    function subMinutes(uint timestamp, uint _minutes) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _minutes * SECONDS_PER_MINUTE;
        require(newTimestamp <= timestamp);
    }
    function subSeconds(uint timestamp, uint _seconds) internal pure returns (uint newTimestamp) {
        newTimestamp = timestamp - _seconds;
        require(newTimestamp <= timestamp);
    }

    function diffYears(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _years) {
        require(fromTimestamp <= toTimestamp);
        (uint fromYear,,) = _daysToDate(fromTimestamp / SECONDS_PER_DAY);
        (uint toYear,,) = _daysToDate(toTimestamp / SECONDS_PER_DAY);
        _years = toYear - fromYear;
    }
    function diffMonths(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _months) {
        require(fromTimestamp <= toTimestamp);
        (uint fromYear, uint fromMonth,) = _daysToDate(fromTimestamp / SECONDS_PER_DAY);
        (uint toYear, uint toMonth,) = _daysToDate(toTimestamp / SECONDS_PER_DAY);
        _months = toYear * 12 + toMonth - fromYear * 12 - fromMonth;
    }
    function diffDays(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _days) {
        require(fromTimestamp <= toTimestamp);
        _days = (toTimestamp - fromTimestamp) / SECONDS_PER_DAY;
    }
    function diffHours(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _hours) {
        require(fromTimestamp <= toTimestamp);
        _hours = (toTimestamp - fromTimestamp) / SECONDS_PER_HOUR;
    }
    function diffMinutes(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _minutes) {
        require(fromTimestamp <= toTimestamp);
        _minutes = (toTimestamp - fromTimestamp) / SECONDS_PER_MINUTE;
    }
    function diffSeconds(uint fromTimestamp, uint toTimestamp) internal pure returns (uint _seconds) {
        require(fromTimestamp <= toTimestamp);
        _seconds = toTimestamp - fromTimestamp;
    }
}

/**
 * @title Date Library
 * 
 * @dev This is a Solidity DateTime Library Wrapper for https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary 's 
 * library an audited Date Time formatted to be used in the PegaBall Contract
 * 
 * uses UTC 0 for the input and result
 */
library Date {

    uint constant DOW_MON = 1;
    uint constant DOW_TUE = 2;
    uint constant DOW_WED = 3;
    uint constant DOW_THU = 4;
    uint constant DOW_FRI = 5;
    uint constant DOW_SAT = 6;
    uint constant DOW_SUN = 7;

    error InvalidDateTime();

    /**
     * custom:function-name getDateFull
     * @param blockTimestamp the timestamp retrieved from block.timestamp or any timestamp 
     * @return month returns a uint256 value representing the month from a given timestamp
     * @return day returns a uint256 value representing the day from a given timestamp
     * @return year returns a uint256 value representing the year from a given timestamp
     * @return hour returns a uint256 value representing the hour from a given timestamp
     * @return minute returns a uint256 value representing the minute from a given timestamp
     * @return second returns a uint256 value representing the second from a given timestamp
     * 
     * @dev this is a function that retrieves the month, day, year, hour, minute, and 
     * second from a given timestamp
     */
    function getDateFull(uint256 blockTimestamp) internal pure returns(uint256 month, uint256 day, uint256 year, uint256 hour, uint256 minute, uint256 second){
        (year, month, day, hour, minute, second) = BokkyPooBahsDateTimeLibrary.timestampToDateTime(blockTimestamp);
    }

    /**
     * custom:function-name getTimestamp
     * @param _month a number representation of month from 1 - 12
     * @param _day a number representation of day from 1 - 31
     * @param _year a year between ORIGIN_YEAR and 3000
     * @param _hour a number representation of hour from 1 - 23
     * @param _minute a number representation of minute from 1 - 59
     * @param _second a number representation of second from 1 - 59
     * @return timestamp returns a uint256 value representing the timestamp equivalent of a 
     * given month, day, year, hour, minute, and second
     * 
     * @dev this is a function that converts a given month, day, year, hour, minute, and second 
     * into a timestamp
     */ 
    function getTimestamp(uint256 _month, uint256 _day, uint256 _year, uint256 _hour, uint256 _minute, uint256 _second) internal pure returns(uint256 timestamp){
        bool isValidDateTime = BokkyPooBahsDateTimeLibrary.isValidDateTime(_year, _month, _day, _hour, _minute, _second);
        if(!isValidDateTime) revert InvalidDateTime();

        return BokkyPooBahsDateTimeLibrary.timestampFromDateTime(_year, _month, _day, _hour, _minute, _second);
    }

    /**
     * custom:function-name getDayOfTheWeek
     * @param blockTimestamp the timestamp retrieved from block.timestamp or any timestamp 
     * @return day returns a uint256 value representing the day of the week from 1 - 7 from a 
     * given timestamp
     * 
     * @dev this is a function that retrieves the day of the week from a given timestamp
     */
    function getDayOfTheWeek(uint256 blockTimestamp) internal pure returns(uint256){
        return BokkyPooBahsDateTimeLibrary.getDayOfWeek(blockTimestamp);
    }

    /**
     * custom:function-name getDayOfTheWeek
     * @param _month a number representation of month from 1 - 12
     * @param _day a number representation of day from 1 - 31
     * @param _year a year between ORIGIN_YEAR and 3000
     * @return day returns a uint256 value representing the day of the week from 1 - 7 from a given 
     * month, day, and year
     * 
     * @dev this is a function that retrieves the day of the week from a given month, day, and year
     */
    function getDayOfTheWeek(uint _month, uint _day, uint _year) internal pure returns(uint256){
        uint256 timestamp = BokkyPooBahsDateTimeLibrary.timestampFromDate(_year, _month, _day);
        return BokkyPooBahsDateTimeLibrary.getDayOfWeek(timestamp);
    }

    /**
     * custom:function-name getNextDayOfTheWeek
     * @param _month a number representation of month from 1 - 12
     * @param _day a number representation of day from 1 - 31
     * @param _year a year between ORIGIN_YEAR and 3000
     * @param _hour a number representation of hour from 1 - 23
     * @param _minute a number representation of minute from 1 - 59
     * @param _second a number representation of second from 1 - 59
     * @return _timestamp returns the timestamp for the next occurrence of the day of the week
     * 
     * @dev this is a function that generates a timestamp for the next occurrence of the day of 
     * the week from the given timestamp   
     */
    function getNextDayOfTheWeek(uint _month, uint _day, uint _year, uint _hour, uint _minute, uint _second) internal pure returns (uint _timestamp){
        uint timestamp = BokkyPooBahsDateTimeLibrary.timestampFromDateTime(_year, _month, _day, _hour, _minute, _second);
        return BokkyPooBahsDateTimeLibrary.addDays(timestamp, 7);
    }

    /**
     * custom:function-name getNextDayOfTheWeek
     * @param _month a number representation of month from 1 - 12
     * @param _day a number representation of day from 1 - 31
     * @param _year a year between ORIGIN_YEAR and 3000
     * @return _timestamp returns the timestamp for the next occurrence of the day of the week
     * 
     * @dev this is a function that generates a timestamp for the next occurrence of the day of 
     * the week from the given timestamp   
     */
    function getNextDayOfTheWeek(uint _month, uint _day, uint _year) internal pure returns (uint _timestamp){
        uint timestamp = BokkyPooBahsDateTimeLibrary.timestampFromDate(_year, _month, _day);
        return BokkyPooBahsDateTimeLibrary.addDays(timestamp, 7);
    }

    /**
     * custom:function-name getNextDayOfTheWeek
     * @param blockTimestamp the timestamp retrieved from block.timestamp or any timestamp 
     * @return _timestamp returns the timestamp for the next occurrence of the day of the week
     * 
     * @dev this is a function that generates a timestamp for the next occurrence of the day of 
     * the week from the given timestamp   
     */
    function getNextDayOfTheWeek(uint256 blockTimestamp) internal pure returns (uint _timestamp){
        return BokkyPooBahsDateTimeLibrary.addDays(blockTimestamp, 7);
    }

    function getNextDrawDate(uint256 blockTimestamp, uint256 draw_hour, uint256 draw_minute, uint256 draw_second) internal pure returns(uint256) {
        uint256 currentDayOfTheWeek = BokkyPooBahsDateTimeLibrary.getDayOfWeek(blockTimestamp);
        (uint256 year, uint256 month, uint256 day, uint256 hour, uint256 minute, uint256 second) = BokkyPooBahsDateTimeLibrary.timestampToDateTime(blockTimestamp);

        uint256 _draw_hour = draw_hour;
        uint256 _draw_minute = draw_minute;
        uint256 _draw_second = draw_second;

        uint256 daysToAdd = 0;

        if(hour >= _draw_hour && minute >= _draw_minute && second >= _draw_second){
            if(currentDayOfTheWeek == DOW_TUE || currentDayOfTheWeek == DOW_FRI || currentDayOfTheWeek == DOW_SUN){
                daysToAdd = 2;
            }
            if(currentDayOfTheWeek == DOW_MON || currentDayOfTheWeek == DOW_WED || currentDayOfTheWeek == DOW_SAT){
                daysToAdd = 1;
            }
            if(currentDayOfTheWeek == DOW_THU){
                daysToAdd = 3;
            }

            return BokkyPooBahsDateTimeLibrary.addDays(BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, day, _draw_hour, _draw_minute, _draw_second), daysToAdd);
        }

        return BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, day, _draw_hour, _draw_minute, _draw_second);
    }

    function getNextDrawDate(uint256 month, uint256 day, uint256 year, uint256 hour, uint256 minute, uint256 second, uint256 draw_hour, uint256 draw_minute, uint256 draw_second) internal pure returns(uint256) {
        uint256 currentTimestamp = BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, day, hour, minute, second);
        uint256 currentDayOfTheWeek = BokkyPooBahsDateTimeLibrary.getDayOfWeek(currentTimestamp);

        uint256 _draw_hour = draw_hour;
        uint256 _draw_minute = draw_minute;
        uint256 _draw_second = draw_second;

        uint256 daysToAdd = 0;

        if(hour >= _draw_hour && minute >= _draw_minute && second >= _draw_second){
            if(currentDayOfTheWeek == DOW_TUE || currentDayOfTheWeek == DOW_FRI || currentDayOfTheWeek == DOW_SUN){
                daysToAdd = 2;
            }
            if(currentDayOfTheWeek == DOW_MON || currentDayOfTheWeek == DOW_WED || currentDayOfTheWeek == DOW_SAT){
                daysToAdd = 1;
            }
            if(currentDayOfTheWeek == DOW_THU){
                daysToAdd = 3;
            }

            return BokkyPooBahsDateTimeLibrary.addDays(BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, day, _draw_hour, _draw_minute, _draw_second), daysToAdd);
        }

        return BokkyPooBahsDateTimeLibrary.timestampFromDateTime(year, month, day, _draw_hour, _draw_minute, _draw_second);
    }

}

abstract contract PegaBallViewFunctionsUpgradeable is PegaBallBaseUpgradeable {
    
    /**
     * @custom:function-name platformPool
     * 
     * @return _platformPool the total withdrawable balance 
     * 
     * @dev this function returns the current balance of the platform
     * pool
     */
    function platformPool() external view returns(uint256){
        PoolStorage storage $ = _getPoolStorage(); 

        return $.platformPool;
    }

    /**
     * @custom:function-name vendorPool 
     * 
     * @return _vendorPool the total withdrawable balance
     * 
     * @dev this function returns the current balance of the vendor 
     * pool
     * 
     * this pool is for the percentage on the jackpot reward the 
     * vendor will get and not the pool for the percentage the
     * vendor will get on buys or on referral buys
     */
    function vendorPool() external view returns(uint256){
        PoolStorage storage $ = _getPoolStorage();

        return $.vendorPool; 
    }

    /**
     * @custom:function-name taxFees 
     * 
     * @return _taxFees the tax fees for tier 1 to 5 prizes
     * 
     * @dev this function returns the tax fees in percent
     * of tier 1 - 5, tier 6, and buy together with their 
     * precision
     */
    function taxFees() external view returns(Tax memory){
        TicketStorage storage $ = _getTicketStorage(); 

        return $.taxFees;
    }

    /**
     * @custom:function-name totalGames 
     * 
     * @return amount the total amount of games bought 
     * 
     * @dev this function returns the amount of total games
     * bought since the begining
     */
    function totalGames() external view returns(uint256){
        InformationStorage storage $ = _getInformationStorage(); 
    
        return $.totalGames;
    }

    /**
     * @custom:function-name gamePrice 
     * 
     * @return _price the current price per game
     * 
     * @dev this function returns the current price of
     * a game in ETH 
     */
    function gamePrice() external view returns(uint256){
        InformationStorage storage $ = _getInformationStorage(); 
    
        return $.gamePrice;
    }

    /**
     * @custom:function-name platformWallet
     * 
     * @return _platformWallet the platform wallet address  
     * 
     * @dev this returns the address of the current admin/plaform account
     */
    function platformWallet() external view returns(address) {
        WalletStorage storage $ = _getWalletStorage();
        return $.PLATFORM_WALLET;
    }

    /**
     * @custom:function-name getDrawResult
     * @param _date the date of the draw 
     * 
     * @return _drawResult the struct of the Draw's information for the specified date
     * 
     * @dev this function is used to retreive the Draw Result from a specified date and will return the default value
     * if that draw has not happen yet
     */
    function getDrawResult(DateType calldata _date) external view returns(DrawResult memory _drawResult) {
        TicketStorage storage $ = _getTicketStorage();
   
        uint256 dayOfWeek = Date.getDayOfTheWeek(_date.month, _date.day, _date.year);
        if(dayOfWeek != Date.DOW_TUE && dayOfWeek != Date.DOW_THU && dayOfWeek != Date.DOW_SUN) revert InvalidDrawDate("Draws are only on Tue, Thu, and Sun UTC");

        uint256 _drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);
        _drawResult = $.drawResult[_drawDate];

    }

    /**
     * @custom:function-name getTotalGamesByDrawDate
     * @param _date draw date
     * 
     * @return totalGames the total amount of games on the given draw date
     * 
     * @dev this function is used to get the total amount of games on a specific draw date
     * for crosschecking during draws to make sure the correct amount of games are being
     * checked for winners
     */
    function getTotalGamesByDrawDate(DateType calldata _date) external view returns(uint256){
        TicketStorage storage $ = _getTicketStorage();

        uint256 drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);
        return $.totalGamesByDrawDate[drawDate];
    }

    /**
     * @custom:function-name getTicketInfo
     * @param _ticketId ticket's id
     * 
     * @return ticketInfo the ticket information
     * 
     * @dev this function returns the ticket information of the given ticket id
     */
    function getTicketInfo(uint256 _ticketId) external view returns(Ticket memory) {
        TicketStorage storage $ = _getTicketStorage();
        return $.tickets[_ticketId];
    }

    /**
     * @custom:function-name getRewardPool
     * @param _date the draw date
     * @return _total the total unclaimed reward's pool
     * @return _pool the pool of an unclaimed reward from a specific draw date
     * 
     * @dev this function is used to view the unclaimed reward pool from a specific date and the toal unclaimed reward pool
     * from all of the draws
     */
    function getRewardPool(DateType calldata _date) external view returns(uint256 _total, uint256 _pool){
        PoolStorage storage $ = _getPoolStorage();
        uint256 _drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);
        
        _total = $.rewardPool.total;
        _pool = $.rewardPool.pool[_drawDate];
    }

    /**
     * @custom:function-name getVendorInfo
     * 
     * @param vendorAddress the address of the vendor the info you want to check
     * 
     * @return _vendorInfo a struct of information about the referrer, receiver wallet, and the referral timer
     * of a vendor
     * 
     * @dev this function is used to view the vendor information of a given address like referrer, receiver wallet, 
     * and referral timer or check if the address is a registered vendor
     */
    function getVendorInfo(address vendorAddress) external view returns (VendorInfo memory){
        TicketStorage storage $ = _getTicketStorage();

        return $.vendor[vendorAddress];
    }

    /**
     * @custom:function-name getWhitelistModeStatus
     * 
     * @param account the address you want to check the whitelist status of
     * 
     * @return whitelistMode a bool indicating if whitelist mode is active or not
     * @return whitelistStatus a bool indicating the whitelist status of an address
     * 
     * @dev this function is used to view the whitelist status of an address and the whitelist mode
     */
    function getWhitelistStatusOf(address account) external view returns(bool whitelistMode, bool whitelistStatus) {
        WhitelistStorage storage $ = _getWhitelistStorage();

        return ($.whitelistMode, $.isWhitelisted[account]);

    }

}

abstract contract PegaBallConfigurationUpgradeable is PegaBallBaseUpgradeable {

    event ChangedWallets(address indexed oldWallet, address indexed newWallet);
    event ChangedGamePrice(address indexed updatedBy, uint256 indexed oldPrice, uint256 indexed newPrice);
    event ChangedTax(uint256 indexed grandPrize, uint256 indexed otherPrize, uint256 indexed buy, uint256 precision);
    event CapsAdjusted(address indexed updatedBy, uint256 indexed newTwentyMillion, uint256 indexed newOneMillion);
    
    /**
     * @custom:function-name setGamePrice
     * 
     * @param newPrice the new game price 
     * in eth 18 decimal format 1 ETH = 1_000_000_000_000_000_000
     * 
     * @custom:access-restrictions PRICE_CHANGER_ROLE
     * prevents any account other than those with PRICE_CHANGER_ROLE to call
     * this function
     * 
     * @dev this function changes the price of a game and adjusts the cap for the next pool
     * and vendor's cut when jackpot is hit
     */
    function setGamePrice(uint256 newPrice) external onlyRole(keccak256("PRICE_CHANGER_ROLE")) {
        InformationStorage storage $ = _getInformationStorage();
        
        address updater = _msgSender();

        uint256 old = $.gamePrice;
        $.gamePrice = newPrice;

        uint256 newTwentyMillion = newPrice * 10_000_000; 
        uint256 newOneMillion = newTwentyMillion / 20; 

        $.TWENTY_MILLION = newTwentyMillion;

        $.ONE_MILLION = newOneMillion;

        emit ChangedGamePrice(updater, old, newPrice);
        emit CapsAdjusted(updater, newTwentyMillion, newOneMillion);
    }
    
    /**
     * @custom:function-name setAllTax
     * 
     * @param _taxFees the tax fee in percent for the buy and the prizes
     * 
     * @custom:access-restrictions Admin
     * prevents any account other than those with DEFAULT_ADMIN_ROLE to call
     * this function
     * 
     * @dev this function changes the tax fees for prizes and buy in percent along with 
     * thier precision (this uses the `calcFeeWithPrecision` function located in `PegaBallCore`)
     */
    function setAllTax(Tax calldata _taxFees) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TicketStorage storage $ = _getTicketStorage();
        
        $.taxFees.buy = _taxFees.buy;
        $.taxFees.grandPrize = _taxFees.grandPrize;
        $.taxFees.otherPrize = _taxFees.otherPrize;
        $.taxFees.precision = _taxFees.precision;

        emit ChangedTax( _taxFees.grandPrize, _taxFees.otherPrize, _taxFees.buy, _taxFees.precision);
    }

    /**
     * @custom:function-name setWallets
     * 
     * @param platform the new platform wallet's address
     * 
     * @custom:access-restrictions Admin
     * prevents any account other than those with DEFAULT_ADMIN_ROLE to call
     * this function
     * 
     * @dev this function changes the wallet address for the platform, while
     * also revoking the Admin Role and other relevant roles from the previous 
     * platform wallet and granting it to the new platform wallet
     */
    function setWallets(address platform) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WalletStorage storage $ = _getWalletStorage();

        address oldWallet = $.PLATFORM_WALLET;

        if(platform == address(0)) revert CanNotBeZeroAddress();
        _revokeRole(DEFAULT_ADMIN_ROLE, oldWallet);
        _revokeRole(keccak256("DRAW_ROLE"), oldWallet);
        _revokeRole(keccak256("VERIFIER_ROLE"), oldWallet);
        _revokeRole(keccak256("PRICE_CHANGER_ROLE"), oldWallet);

        _grantRole(DEFAULT_ADMIN_ROLE, platform);
        _grantRole(keccak256("DRAW_ROLE"), platform);
        _grantRole(keccak256("VERIFIER_ROLE"), platform);
        _grantRole(keccak256("PRICE_CHANGER_ROLE"), platform);

        $.PLATFORM_WALLET = platform;
        
        emit ChangedWallets(oldWallet, platform);
    }

    /**
     *  @custom:function-name toggleWhitelistMode
     * 
     * @custom:access-restrictions Admin
     * prevents any account other than those with DEFAULT_ADMIN_ROLE to call
     * this function
     * 
     * @dev this function enables and disables whitelist mode for buying games
     * allowing only accounts who are whitelisted to buy games
     */
    function toggleWhitelistMode() external onlyRole(DEFAULT_ADMIN_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();

        $.whitelistMode = !$.whitelistMode;

    }

    /**
     *  @custom:function-name toggleWhitelistFor
     * 
     * @param accounts the list of addresses to be added or removed from the whitelist
     * 
     * @custom:access-restrictions Admin
     * prevents any account other than those with DEFAULT_ADMIN_ROLE to call
     * this function
     * 
     * @dev this function toggles a list of addresses' whitelist status
     */
    function toggleWhitelistFor(address[] calldata accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        WhitelistStorage storage $ = _getWhitelistStorage();
        uint256 length = accounts.length;
        uint256 i;
        do{
            address _account = accounts[i];
            $.isWhitelisted[_account] = !$.isWhitelisted[_account];
            unchecked { i++; }
        }while(i < length);
        
    }

}

abstract contract PegaBallCoreUpgradeable is PegaBallBaseUpgradeable, LockableUpgradeable, PegaBallConfigurationUpgradeable, PegaBallViewFunctionsUpgradeable {

    uint256 constant NOT_CLAIMED = 0;
    uint256 constant CLAIMED = 1;

    event BuyGames(address indexed ticketOwner, uint256 indexed ticketType, uint256 indexed drawDate, uint256 gameIdStart, uint256 gameIdEnd, uint256 ticketId, uint256 boughtDate);
    event Claims(address indexed claimer, uint256 indexed ticketAmount, uint256 indexed totalAmount);
    event Draw(uint256 indexed drawDate, LotteryNumbers winningNumbers, uint256 indexed id, uint256 indexed totalRewards, uint256 prizePoolSnapshot);
    event VendorRegistered(address indexed registrant, address indexed referrer, address indexed receiver, uint256 timerEnd);
    event UpdateVendorReceiver(address indexed oldReceiver, address indexed newReceiver);
    event RecordedOwnership(GameOwnership[] gameOwners, uint256 indexed ticketId, uint256 indexed totalAmount, uint256 indexed drawDate);

    /**
     * @custom:function-name __PegaBallCore_init
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallCore_init(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) internal { 
                    
        __PegaBallCore_init_unchained(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);

    }
    
    /**
     * @custom:function-name __PegaBallCore_init_unchained
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallCore_init_unchained(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) private { 

        __PegaBallBase_init(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);
    
    }

    /**
     * @custom:function-name _buyGames
     * @param buyer the address of the ticket buyer
     * @param ticketType the ticket type `1` - pegaball `2` - third party ticket vendor
     * @param _amount the amount of tickets
     * @param _drawDate the draw date of the ticket
     * 
     * @return _price the total price of all games
     * 
     * @dev this function is an internal one that cannot be accessed publicly and is used in `buyTickets` function to
     * change some states in the contract and emit a `BuyGames` Event
     */
    function _buyGames(address buyer, uint256 ticketType, uint256 _amount, uint256 _drawDate) internal virtual returns(uint256 _price) {
        InformationStorage storage $ = _getInformationStorage();
        TicketStorage storage $$$ = _getTicketStorage();

        unchecked{ ++$.ticketCount; }

        uint256 gameIdStart = $.totalGames + 1;
        uint256 gameIdEnd = gameIdStart + (_amount - 1);

        address _buyer = buyer;
        uint256 price = $.gamePrice * _amount;
        uint256 drawDate = _drawDate;
        uint256 _ticketId = $.ticketCount;
        uint256 _ticketType = ticketType;

        emit BuyGames(_buyer, _ticketType, drawDate, gameIdStart, gameIdEnd, _ticketId, block.timestamp);

        $$$.totalGamesByDrawDate[drawDate] += _amount;

        $$$.tickets[_ticketId] = Ticket({ticketType: _ticketType, from: gameIdStart, to: gameIdEnd, drawDate: drawDate, ticketOwner: _buyer});

        $.totalGames += _amount;

        return price;
    }

    /**
     * @custom:function-name _claims
     * 
     * @param _claimInfo a list of data about the ticket to be claimed
     * @custom:sub-param `_claimInfo` - `ticketId` the Id of the winning ticket a user wants to claim
     * @custom:sub-param `_claimInfo` - `id` the id of the game to be claimed
     * @custom:sub-param `_claimInfo` - `tier` the tier of the game assigned with the prize value
     * @custom:sub-param `_claimInfo` - `messageHash` the hashed message using 
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))` as the message  parameter following
     * the signed data standard EIP-191
     * @custom:sub-param `_claimInfo` - `signature` the signature from an address with
     * the role of keccack256("VERIFIER_ROLE") and a message parameter of
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))`
     * @param _date the draw date of the winning ticket
     * @param claimer the caller's address
     * 
     * @dev this function is an internal one that cannot be accessed publicly and is used in `claims` function to
     * change some states in the contract and emit a `Claims` Event
     * 
     * the verification uses openzeppelin's ECDSA to retrive the
     * signer and check if the sgner has the VERIFIER_ROLE
     * and if the hashed message provided is equal to the
     * generated hashed message * for it to be considered 
     * valid
     * 
     * Rewards are divided into 6 tiers
     * 
     * Tier | Equivalent to PowerBall |        in Pegaball
     * -----|-------------------------| ------------------------------
     *   1  |  $4                     |
     *   2  |  $7                     |
     *   3  |  $100                   |
     *   4  |  $50_000                | 0.25% of pool (capped at $50k)
     *   5  |  $1_000_000             | 5% of pool (capped at $1M)
     *   6  |  $JACKPOT               |
     */
    function _claims(ClaimInfo[] calldata _claimInfo, DateType calldata _date, address claimer) internal virtual returns(uint256 _amountTotal){
        
        PoolStorage storage $$ = _getPoolStorage();
        TicketStorage storage $$$ = _getTicketStorage();

        uint256 currentTime = block.timestamp;
        uint256 length = _claimInfo.length;
        uint256 drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);
        
        if(currentTime >= (drawDate + 365 days)) revert TicketIsExpired();

        ClaimInfo[] calldata _claimInfos = _claimInfo;
        uint256 amountTotal = 0;
        
        uint256 i;
        do{
            Ticket memory _tickets = $$$.tickets[_claimInfos[i].ticketId];

            if (_tickets.drawDate != drawDate) revert DrawDateNotMatching();
            if ((_tickets.ticketType == 2) && (_tickets.ticketOwner == claimer)) revert ClaimerCanNotBeVendor();
            if ($$$.isClaimed[_claimInfos[i].gameId] != NOT_CLAIMED) revert AlreadyClaimed(_claimInfos[i].gameId);
            if (_claimInfos[i].tier == 0) revert NotAWinner();

            address ticketOwner = getTicketOwner(_claimInfos[i].ticketId, _claimInfos[i].gameId);
            
            if((_tickets.ticketType == 1) && (claimer != ticketOwner)) revert InvalidTicketOwner();
            
            verifyTier(_claimInfos[i], claimer);

            $$$.isClaimed[_claimInfos[i].gameId] = CLAIMED;

            amountTotal += _tierToPrize(_claimInfos[i].tier, drawDate);
      
            unchecked { ++i; }
        } while(i < length);

        $$.rewardPool.total -= amountTotal;
        $$.rewardPool.pool[drawDate] -= amountTotal;

        emit Claims(claimer, length, amountTotal);

        return amountTotal;
    }

    /**
     * @custom:function-name _draw
     * @param _date the draw date in unix timestamp seconds format
     * @param game the lottery numbers
     * @param _winnerCount the number of winners per tier
     * @param _prizePool the prize pool for the current draw
     * 
     * @dev this function is an internal one that cannot be accessed publicly and is used in `draw` function to store the draw result on chain
     * and the emit a `Draw` event containg the draw's information
     */
    function _draw(DateType calldata _date, LotteryNumbers calldata game, WinnersPerTier calldata _winnerCount, uint256 _prizePool) internal virtual {
        InformationStorage storage $ = _getInformationStorage();
        PoolStorage storage $$ = _getPoolStorage();
        TicketStorage storage $$$ = _getTicketStorage();

        unchecked { ++$.drawCount; }
        
        uint256 _drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);

        uint256 _drawDateDayOfWeek = Date.getDayOfTheWeek(_drawDate);

        DrawResult memory _drawResult = $$$.drawResult[_drawDate];
        LotteryNumbers calldata _game = game;

        if(_drawDateDayOfWeek != uint256(DayOfWeek.TUESDAY) && _drawDateDayOfWeek != uint256(DayOfWeek.THURSDAY) && _drawDateDayOfWeek != uint256(DayOfWeek.SUNDAY)) revert InvalidDrawDate("Draws are only on Tue, Thu, and Sun UTC");
        if(block.timestamp < _drawDate) revert DrawHasNotHappenedYet();

        $$$.winnersPerTier[_drawDate] = _winnerCount;
        WinnersPerTier calldata _wins = _winnerCount;

        uint256 currentPool = (_drawResult.prizePoolSnapshot != 0) ? _drawResult.prizePoolSnapshot : _prizePool;

        TierValue memory _tierValue = _getFullPrizesPerTier(currentPool, _wins, $.gamePrice);
        (TierValue memory _taxPerTier, uint256 _platformTotal) = _getPlatformTax($.TWENTY_MILLION,_tierValue, $$$.taxFees, _wins);
        (TierValue memory _prizePerTier, uint256 _totalRewards, uint256 _vendorTotal) = _getRewardsPerTier(_tierValue, _taxPerTier, _wins);
        
        $$$.tierPrizes[_drawDate] = TierPrizes(0, _prizePerTier.tier1, _prizePerTier.tier2, _prizePerTier.tier3, _prizePerTier.tier4, _prizePerTier.tier5, _prizePerTier.tier6);
                
        if(_drawResult.totalRewardSnapshot != 0){
            // this section resets the pools to 0 during re-draw
            $$.platformPool -= _drawResult.totalPlatformTaxSnapshot;
            $$.vendorPool -= _drawResult.vendorTotalSnapshot;
            $$.rewardPool.total -= _drawResult.totalRewardSnapshot;
            $$.rewardPool.pool[_drawDate] = 0;

            // this section sets the pools during re-draw
            $$.platformPool += _platformTotal;
            $$.vendorPool += _vendorTotal;
            $$.rewardPool.total += _totalRewards;
            $$.rewardPool.pool[_drawDate] = _totalRewards;
        } else {
            // this section sets the pools if it's the first draw and not a re-draw
            $$.platformPool += _platformTotal;
            $$.vendorPool += _vendorTotal;
            $$.rewardPool.total += _totalRewards;
            $$.rewardPool.pool[_drawDate] = _totalRewards;
        }

        uint256 drawId = $.drawCount;

        // saves the balance snapshots and draw result on a state 
        $$$.drawResult[_drawDate] = DrawResult({
            id: drawId,
            prizePoolSnapshot: currentPool,
            vendorTotalSnapshot: _vendorTotal,
            totalPlatformTaxSnapshot: _platformTotal,
            totalRewardSnapshot: _totalRewards,
            game: _game
        });

        emit Draw(_drawDate, _game, drawId, _totalRewards, currentPool);
    }

    /**
     * @custom:function-name verifyTier
     * @param _claimInfo a list of data about the ticket to be claimed
     * @custom:sub-param `_claimInfo` - `id` the id of the game to be claimed
     * @custom:sub-param `_claimInfo` - `tier` the tier of the game assigned with the prize value
     * @custom:sub-param `_claimInfo` - `messageHash` the hashed message using 
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))` as the message  parameter following
     * the signed data standard EIP-191
     * @custom:sub-param `_claimInfo` - `signature` the signature from an address with
     * the role of keccack256("VERIFIER_ROLE") and a message parameter of
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))`
     * @param _gameOwner the address of the game owner
     * 
     * @dev this function is used to verify if a game's tier is a valid one for claiming,
     * this is to make sure winning games are only claiming rewards that matches the correct amount
     */
    function verifyTier(ClaimInfo calldata _claimInfo, address _gameOwner) internal view {
        bytes32 hashed = keccak256(abi.encodePacked(_gameOwner, _claimInfo.gameId, _claimInfo.tier));
        bytes32 msgHash = keccak256(bytes.concat("\x19Ethereum Signed Message:\n", bytes(Strings.toString(hashed.length)), hashed));

        (address _signer, ECDSA.RecoverError _error,) = ECDSA.tryRecover(msgHash, _claimInfo.signature);
        
        bool isVerifier = hasRole(keccak256("VERIFIER_ROLE"), _signer);

        if((_claimInfo.hashedMessage != msgHash) || !isVerifier || (_error != ECDSA.RecoverError.NoError)) revert InvalidPrizeTierInformation();
    } 

    /**
     * @custom:function-name getTicketOwner
     * @param _ticketId ticket's id
     * @param _gameId game's id
     * 
     * @return address the address of the ticket's owner
     * 
     * @dev this function returns the owner of a ticket/game given it's `ticket id` and `game id`
     * will return the zero address if the `ticket id` and `game id` does not match or if the
     * ticket/game does not exist yet  
     */
    function getTicketOwner(uint256 _ticketId, uint256 _gameId) public view returns(address){
        TicketStorage storage $ = _getTicketStorage();
        Ticket memory _gamesByTicket = $.tickets[_ticketId];

        if(_gameId < _gamesByTicket.from || _gameId > _gamesByTicket.to) return address(0);

        return _gamesByTicket.ticketOwner;
    }

    /**
     * @custom:function-name nextDrawDate
     * 
     * @return uint256 the timestamp of the nearest draw date and time
     * 
     * @dev this function uses the date library to get the timestamp that solidity uses
     * from date and time to generate the timestamp in seconds for the next draw date in UTC
     * based on Powerball's schedule 
     * 
     * PegaBall Draw Schedule in EST
     * Time: 10:59:00 PM
     * Days: Mon, Wed, Sat
     * 
     * in UTC
     * Time: 2:59 AM
     * Days: Tue, Thu, Sun
     * 
     * Time used in contract is with an additional 1 minute
     * 
     * 11:00:00 PM EST
     * 3:00:00 AM UTC
     */
    function nextDrawDate() public view virtual returns(uint256) {
        uint256 currentTime = block.timestamp;
        return Date.getNextDrawDate(currentTime, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);
    }

    /**
     * @custom:function-name vendorRegistration
     * 
     * @param _referrer address of the referrer (must be zero address if there are no referrer)
     * @param _receiverWallet address where the vendor will receive the 10% cut from the buy tax
     * 
     * @custom:access-restrictions None
     * 
     * @dev this function is used to register a vendor/vendor in the contract allowing them to
     * access the `buyGamesFrom` function which would give them access to perks like get 10% of buy tax
     * 
     * the referrer will also get 10% of buy tax for a duration of 60 days for every buy the vendor/vendor
     * executes for every referral they get 
     */
    function vendorRegistration(address _referrer, address _receiverWallet) external {
        TicketStorage storage $ = _getTicketStorage();
        address registrant = _msgSender();
        uint256 currentTime = block.timestamp;
        uint256 timer = (currentTime + 60 days);

        if(_receiverWallet == address(0)) revert CanNotBeZeroAddress();
        if($.vendor[registrant].isVendor != 0) revert VendorAlreadyRegistered();

        $.vendor[registrant] = VendorInfo({
            referrer: _referrer,
            receiver: _receiverWallet,
            isVendor: 1,
            timer: timer
        });
        emit VendorRegistered(registrant, _referrer, _receiverWallet, timer);
    }

    /**
     * @custom:function-name updateVendorReceiverWallet
     *  
     * @param newReceiverWallet the vendor's new wallet where the 10% of the
     * buy tax will be sent
     * 
     * @dev this function allows the vendor to update the wallet that will receive
     * their 10% cut on the buy tax
     */
    function updateVendorReceiverWallet(address newReceiverWallet) external {
        TicketStorage storage $ = _getTicketStorage();
        
        address _vendor =_msgSender(); 
        address oldReceiver = $.vendor[_vendor].receiver;

        if($.vendor[_vendor].isVendor != 1) revert NotAVendor();
        if(newReceiverWallet == address(0)) revert CanNotBeZeroAddress();

        $.vendor[_vendor].receiver = newReceiverWallet;

        emit UpdateVendorReceiver(oldReceiver, newReceiverWallet);
    }

    /**
     * @custom:function-name receive
     * 
     * @dev default solidity fallback function for allowing the contract to receive ETH
     */
    receive() external payable {}

    /**
     * @custom:function-name _getFullPrizesPerTier
     * @param _pool the current prize pool
     * @param _winnerCount the number of winners per tier
     * 
     * @dev this function is used to calculate the amount of prize each win per tier gets before tax and deductions
     */
    function _getFullPrizesPerTier(uint256 _pool, WinnersPerTier calldata _winnerCount, uint256 _gamePrice) internal pure returns(TierValue memory _tierValue) {
        
        WinnersPerTier calldata _winCount = _winnerCount;
        uint256 __pool = _pool;

        uint256 tier4 = calcFeeWithPrecision(__pool, 250_000, 6); // 0.25% of the prize pool
        uint256 tier5 = calcFeeWithPrecision(__pool, 5_000_000, 6); // 5% of the prize pool
        
        uint256 tier1PerWin = (_gamePrice * 2); // equivalent to $4 
        uint256 tier2PerWin = ((_gamePrice * 3) + (_gamePrice / 2)); // equivalent to $7
        uint256 tier3PerWin = (_gamePrice * 50); // equivalent to $100
        uint256 tier4PerWin = ((tier4 >= (_gamePrice * 25_000)) ? (_gamePrice * 25_000) : tier4); // equivalent to 0.25% capped to $50_000
        uint256 tier5PerWin = ((tier5 >= (_gamePrice * 500_000)) ? (_gamePrice * 500_000) : tier5); // equivalent to 5% capped to $1_000_000

        // subtraccts all winnings from tier 1 - 5 and diveded by the amount of winners
        // initial check for if tier 6 winner count is 0 = 0 is to prevent divide by zero error  
        uint256 tier6PerWin = _winCount.tier6 == 0 ? 0 : ((
            __pool - 
            (tier1PerWin * _winCount.tier1) -
            (tier2PerWin * _winCount.tier2) -
            (tier3PerWin * _winCount.tier3) -
            (tier4PerWin * _winCount.tier4) -
            (tier5PerWin * _winCount.tier5)
            ) / _winCount.tier6);
        // sets the values of each tier reward per win before taxes
        _tierValue = TierValue(
            tier1PerWin,
            tier2PerWin,
            tier3PerWin,
            tier4PerWin,
            tier5PerWin,
            tier6PerWin
        );
    }

    /**
     * @custom:function-name _getRewardsPerTier
     * @param _tierValue the reward amount for tier 1 - 6 for a single win
     * @param _taxPerTier the tax amount from the rewards for tier 1 - 6 for a single win
     * @param _wins the number of winners per tier
     * @return _rewards the rewards per tier after tax deductions
     * @return _total the total rewards calculated by the amount of winners and the rewards per winner
     * @return _vendorTotal the amount that the vendor would get if the jackpot is hit, it is 10%
     * of the claimable amount
     * 
     * @dev this function is used to calculate the actual rewards each win would get after every draw for each tier
     * and the total rewards to be subtracted from the next draw's prize pool
     */
    function _getRewardsPerTier(TierValue memory _tierValue, TierValue memory _taxPerTier, WinnersPerTier calldata _wins) internal pure returns(TierValue memory, uint256 _total, uint256 _vendorTotal){
        
        uint256 _tier1 = _tierValue.tier1 - _taxPerTier.tier1;
        uint256 _tier2 = _tierValue.tier2 - _taxPerTier.tier2;
        uint256 _tier3 = _tierValue.tier3 - _taxPerTier.tier3;
        uint256 _tier4 = _tierValue.tier4 - _taxPerTier.tier4;
        uint256 _tier5 = _tierValue.tier5 - _taxPerTier.tier5;
        // since the tier value's tier 6 is equivalent to 1 user's win, we multiple it to the
        // winner count to get the original jackpot amount before the division
        uint256 _tier6 = (_tierValue.tier6 * _wins.tier6) - _taxPerTier.tier6;

        // this calculates the amount the vendor will get from the jackpot
        _vendorTotal = (_wins.tier6 == 0) ? 0 : calcFeeWithPrecision((_tier6 / _wins.tier6), 10, 0);
        
        uint256 _tier6RewardPerWinner =  ((_wins.tier6 == 0) ? 0 : ((_tier6 / _wins.tier6) - (_vendorTotal / _wins.tier6)) );
        
        // this is used to keep tract of the total rewards per draw after tax
        _total = (
            (_tier1 * _wins.tier1) + 
            (_tier2 * _wins.tier2) + 
            (_tier3 * _wins.tier3) + 
            (_tier4 * _wins.tier4) + 
            (_tier5 * _wins.tier5) + 
            (_tier6 - _vendorTotal)
            );

        return (TierValue(_tier1, _tier2, _tier3, _tier4, _tier5, _tier6RewardPerWinner), _total, _vendorTotal);
    }

    /**
     * @custom:function-name _getPlatformTax
     * @param _twentyMillion twenty million
     * @param _tierValue the reward amount for tier 1 - 6 for a single win
     * @param _taxFees the tax fees in percent including their precision
     * @param _winnerCount  the number of winners per tier
     * @return _taxPerTier the tax in percent for each win
     * @return _total the total amount of tax the platform would receive 
     * 
     * @dev this function is used to calculate the total amount the platform would get after every draw
     * which will also be subtracted from the next draw's prize pool
     */
    function _getPlatformTax(uint256 _twentyMillion, TierValue memory _tierValue, Tax memory _taxFees, WinnersPerTier memory _winnerCount) internal pure returns(TierValue memory _taxPerTier, uint256 _total){
        WinnersPerTier memory _winCount = _winnerCount;
        TierValue memory __tierValue = _tierValue;

        uint256 _tier1 = calcFeeWithPrecision(__tierValue.tier1, _taxFees.otherPrize, _taxFees.precision);
        uint256 _tier2 = calcFeeWithPrecision(__tierValue.tier2, _taxFees.otherPrize, _taxFees.precision);
        uint256 _tier3 = calcFeeWithPrecision(__tierValue.tier3, _taxFees.otherPrize, _taxFees.precision);
        uint256 _tier4 = calcFeeWithPrecision(__tierValue.tier4, _taxFees.otherPrize, _taxFees.precision);
        uint256 _tier5 = calcFeeWithPrecision(__tierValue.tier5, _taxFees.otherPrize, _taxFees.precision);
        uint256 _tier6 = calcFeeWithPrecision((__tierValue.tier6 * _winCount.tier6), _taxFees.grandPrize, _taxFees.precision); // amount the platform will get
        uint256 _tier6Total = (__tierValue.tier6 * _winCount.tier6);
        
        _taxPerTier = TierValue(_tier1, _tier2, _tier3, _tier4, _tier5, _tier6);
        
        // this is what will remain on the contract for the next draw
        // if the jackpot is hit 
        uint256 _remaining = calcFeeWithPrecision(_tier6Total, 10, 0);
        _remaining = (_remaining >= _twentyMillion) ? _twentyMillion : _remaining;
        
        // total amount the platform pool will get after the draw
        _total = (
                (_tier1 * _winCount.tier1) + 
                (_tier2 * _winCount.tier2) + 
                (_tier3 * _winCount.tier3) + 
                (_tier4 * _winCount.tier4) + 
                (_tier5 * _winCount.tier5) +
                // 30% for the platform - 10% remaining for the next draw capped at 20M, a total of 20% for the platform 
                (_tier6 - _remaining) 
                );
    }

    /**
     * @custom:function-name _tierToPrize
     * @param tier the tier of the ticket
     * @param _drawDate the ticket's draw date
     * 
     * @dev this function is used in `claims` function to retrieve the amount the winner could claim
     * in ETH based on the tier their game is on
     */
    function _tierToPrize(uint256 tier, uint256 _drawDate) internal view returns(uint256 prize){
        TicketStorage storage $ = _getTicketStorage();
        
        TierPrizes memory _tierPrizes = $.tierPrizes[_drawDate];

        if(tier == uint256(Tiers.ONE)) return _tierPrizes.tier1;
        if(tier == uint256(Tiers.TWO)) return _tierPrizes.tier2;
        if(tier == uint256(Tiers.THREE)) return _tierPrizes.tier3;
        if(tier == uint256(Tiers.FOUR)) return _tierPrizes.tier4;
        if(tier == uint256(Tiers.FIVE)) return _tierPrizes.tier5;
        if(tier == uint256(Tiers.SIX)) return _tierPrizes.tier6;

        // this two are fail safes and hopefully won't get used
        
        // tier 0 won't get used because of the NotAWinner revert on
        // claims
        if(tier == uint256(Tiers.ZERO)) return _tierPrizes.tier0;
        
        // return 0 is the same as tier 0 to make sure that if 
        // none of the tiers 1 - 5 are passed it will default 
        // the reward will default to 0 
        return 0;
    }

    /**
    * @custom:function-name calcFeeWithPrecision
    * @dev calculates the precise amount in fee
    * 
    * `originalAmount` - the originalAmount to be converted
    * `fee` - the amount of fee to be outputed in percent based on the precision
    * `precision` - number of decimal places between 0 and 1 or the amount of 0
    * after 100 to accomodate uint's lack of decimal numbers
    * 
    * precision | range
    * 0         | 100 = 100% and 1 = 1%
    * 1         | 1_000 = 100% and 1 - 0.1%
    * 2         | 10_000 = 100% and 1 = 0.01%
    * 
    * more precision means more zeroes between 0 and 1
    * 
    * Limitations:
    *     when the result underflows it will return 0 
    */
    function calcFeeWithPrecision(uint256 originalAmount, uint256 fee, uint256 precision) internal pure returns(uint256) {
        
        uint256 denominator = (10 ** ( 2 + (1 * precision) ) );

        // this part is necessary to make sure that the function won't use a fee/percentage 
        // more than 100 percent
        if (fee > denominator) revert InvalidFeeError("Fee can't exceed the denominator");
                
        return (originalAmount * fee) / denominator;
    }
}

abstract contract PegaBallUpgradeable is PegaBallCoreUpgradeable {

    event Withdraw(string indexed assetType, uint256 indexed amount);
    
    /**
     * @custom:function-name __PegaBallUpgradeable_init
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallUpgradeable_init(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) internal {
     
        __PegaBallUpgradeable_init_unchained(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);

    }

    /**
     * @custom:function-name __PegaBallUpgradeable_init_unchained
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev https://docs.openzeppelin.com/contracts/5.x/upgradeable#multiple-inheritance for more info
     */
    function __PegaBallUpgradeable_init_unchained(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) internal {

        __PegaBallCore_init(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);
        
    }

    /**
     * @custom:function-name buyGames
     * @param _amount amount of games to buy
     * 
     * @custom:access-restrictions Lock, Balance
     * prevents buying tickets when it is locked or when there's not enough ETH balance in the user's wallet,
     * ETH must also be pre-approved with the contract as the spender
     * 
     * @dev this function allows one to buy one or multiple games of type 1 for the lottery's next draw and emit a
     * `BuyGames` Event
     * 
     * Game data will be saved on another chain where the gas fee is low enough (current choice: gnosis chain) to ensure 
     * that the users will have a way to retreive their ticket data for cross verification allowing them to verify if 
     * their ticket has been tampered with during the prize distribution
     */
    function buyGames(uint256 _amount) external payable nonReentrant hasETHBalance(_amount) isBuyNotLocked {
        
        TicketStorage storage $ = _getTicketStorage();
        WhitelistStorage storage $$ = _getWhitelistStorage();

        BuyGamesInfo memory info = BuyGamesInfo({
            buyer: _msgSender(),
            ticketType: 1, // pegaball
            drawDate: nextDrawDate()
        });

        if($.vendor[info.buyer].isVendor != 0) revert IsAVendor();
        if($$.whitelistMode && !$$.isWhitelisted[info.buyer]) revert NotInTheWhitelist();

        uint256 price = _buyGames(info.buyer, info.ticketType, _amount, info.drawDate);

        // distributes the buy tax to the platform pool and deducts the referrer and vendor cut for ticket type 2 
        _distributeBuyTax(price, $.taxFees.buy, $.taxFees.precision, info.ticketType, $.vendor[info.buyer]);

        (bool success,) = payable(this).call{ value: price}("");
        require(success, "Failed To Send ETH!");
    }

    /**
     * @custom:function-name buyGamesFrom
     * @param _amount amount of games to buy
     * 
     * @custom:access-restrictions Lock, Balance
     * prevents buying tickets when it is locked or when there's not enough ETH balance in the user's wallet,
     * ETH must also be pre-approved with the contract as the spender
     * 
     * @dev this function allows one to buy one or multiple games of type 2 for the lottery's next draw on behalf of others
     * and will emit a `BuyGames` Event.
     * 
     * this function will be used mainly by third party ticket vendors
     * 
     * Game data will be saved on another chain where the gas fee is low enough to ensure that the users will have a way 
     * to retreive their ticket data for cross verification allowing them to verify if their ticket has been tampered with 
     * during the prize distribution
     * 
     * Ticket Informations and game ownerships will be send by the ticket vendors through a provided API before being saved
     * on another chain
     */
    function buyGamesFrom(uint256 _amount) external payable nonReentrant hasETHBalance(_amount) isBuyNotLocked {
        
        TicketStorage storage $ = _getTicketStorage();
        WhitelistStorage storage $$ = _getWhitelistStorage();
        
        BuyGamesInfo memory info = BuyGamesInfo({
            buyer: _msgSender(),
            ticketType: 2, // vendor
            drawDate: nextDrawDate()
        });

        if($.vendor[info.buyer].isVendor != 1) revert NotAVendor();
        if($$.whitelistMode && !$$.isWhitelisted[info.buyer]) revert NotInTheWhitelist();
        
        uint256 price = _buyGames(info.buyer, info.ticketType, _amount, info.drawDate);

        (bool success,) = payable(this).call{ value: price}("");
        require(success, "Failed To Send ETH!");

        // distributes the buy tax to the platform pool and deducts the referrer and vendor cut for ticket type 2 
        (uint256 referrerCut, uint256 vendorCut) = _distributeBuyTax(price, $.taxFees.buy, $.taxFees.precision, info.ticketType, $.vendor[info.buyer]);
        
        // will send the 10% of the buy tax to the receiver the vendor set during registration (can be updated)
        (bool success1,) = payable($.vendor[info.buyer].receiver).call{ value: vendorCut}("");
        require(success1, "Failed To Send ETH!");

        // will send the referrer reward if it's not equal to 0 and the referrer address is not the zero address
        if(referrerCut > 0 && $.vendor[info.buyer].referrer != address(0)){
            (bool success2,) = payable($.vendor[info.buyer].referrer).call{ value: referrerCut}("");
            require(success2, "Failed To Send ETH!");
        }
    }
    
    /**
     * @custom:function-name buyGamesFrom (with Ownership Data)
     * @param _amount total amount of games to buy separate from the amount of game owners
     * @param _gameOwners list of ownerships | front end format [[gameOwner, amount], ...] ex. [[ 0x01 , 1 ], [ 0x02 , 10]]
     * @custom:sub-param _gameOwners : gameOwner - the owner of a certain amount of games
     * @custom:sub-param _gameOwners : amount - amount of games owned by an address
     * 
     * @custom:access-restrictions Lock, Balance
     * prevents buying tickets when it is locked or when there's not enough ETH balance in the user's wallet,
     * ETH must also be pre-approved with the contract as the spender
     * 
     * @dev this function is an overloaded version of the function with the same name made for vendors who would prefer to pay more
     * for gas to not use the API provided by PegaBall for storing game ownership data for personal or security reasons.
     * 
     * it allows one to buy one or multiple games of type 2 for the lottery's next draw on behalf of others
     * and will emit a `BuyGames` Event and a `RecordedOwnership` event where the game ownership would be recorded.
     * 
     * this function will be used mainly by third party ticket vendors
     * 
     * Game data will be saved on another chain where the gas fee is low enough to ensure that the users will have a way 
     * to retreive their ticket data for cross verification allowing them to verify if their ticket has been tampered with 
     * during the prize distribution 
     */
    function buyGamesFrom(uint256 _amount, GameOwnership[] calldata _gameOwners) external payable nonReentrant hasETHBalance(_amount) isBuyNotLocked {
        InformationStorage storage $ = _getInformationStorage();
        WhitelistStorage storage $$ = _getWhitelistStorage();
        TicketStorage storage $$$ = _getTicketStorage();
        unchecked{ ++$.ticketCount; }

        uint256 amount = _amount;
        uint256 gameIdStart = ($.totalGames + 1);
        GameOwnership[] calldata gameOwners = _gameOwners;
        BuyGamesFromInfo memory info = BuyGamesFromInfo({
            vendor: _msgSender(),
            ticketType: 2, // vendor
            drawDate: nextDrawDate(),
            price: ($.gamePrice * amount),
            gameIdEnd: (gameIdStart + (amount - 1)),
            ticketId: $.ticketCount
        });
        
        if($$$.vendor[info.vendor].isVendor != 1) revert NotAVendor();
        if($$.whitelistMode && !$$.isWhitelisted[info.vendor]) revert NotInTheWhitelist();

        emit BuyGames(info.vendor, info.ticketType, info.drawDate, gameIdStart, info.gameIdEnd, info.ticketId, block.timestamp);
        
        emit RecordedOwnership(gameOwners, info.ticketId, amount, info.drawDate);

        $$$.totalGamesByDrawDate[info.drawDate] += amount;

        $$$.tickets[info.ticketId] = Ticket({ticketType: info.ticketType, from: gameIdStart, to: info.gameIdEnd, drawDate: info.drawDate, ticketOwner: info.vendor});

        $.totalGames += amount;

        (bool success,) = payable(this).call{ value: info.price}("");
        require(success, "Failed To Send ETH!");

        // distributes the buy tax to the platform pool and deducts the referrer and vendor cut for ticket type 2 
        (uint256 referrerCut, uint256 vendorCut) = _distributeBuyTax(info.price, $$$.taxFees.buy, $$$.taxFees.precision, info.ticketType, $$$.vendor[info.vendor]);
        
        // will send the 10% of the buy tax to the receiver the vendor set during registration (can be updated)
        (bool success1,) = payable($$$.vendor[info.vendor].receiver).call{ value: vendorCut}("");
        require(success1, "Failed To Send ETH!");

        // will send the referrer reward if it's not equal to 0 and the referrer address is not the zero address
        if(referrerCut > 0 && $$$.vendor[info.vendor].referrer != address(0)){
            (bool success2,) = payable($$$.vendor[info.vendor].referrer).call{ value: referrerCut}("");
            require(success2, "Failed To Send ETH!");
        }
    }

    /**
     * @custom:function-name _distributeBuyTax
     *  
     * @param price the ticket's total price
     * @param buyTaxFee the current buy tax
     * @param precision the precision of the buy tax
     * @param ticketType the ticket type `1` - platform | `2` - vendor
     * @param $$ the vendor info storage as memory
     * @return referrerCut how much the referrer will get
     * @return vendorCut how much the vendor will get
     * 
     * @dev this function is used to distribute the buy tax to the platform pool, vendor, and referrer
     * 
     * will only distribute to vendor if ticket type is 2 and ticket is bought using `buyGamesFrom`
     * will only distribute to referrer if the timer greater than or equal to the current time, meaning the 
     * referral reward is still active
     */
    function _distributeBuyTax(uint256 price, uint256 buyTaxFee, uint256 precision, uint256 ticketType, VendorInfo memory $$) internal returns(uint256 referrerCut, uint256 vendorCut) {
        PoolStorage storage $ = _getPoolStorage();

        uint256 referrerCutPercentage = 0;
        uint256 vendorCutPercentage = 0;
        
        if(ticketType == 2){
            // this will check if the timer is greater than or equal to the current time
            // meaning the referral reward is still active
            referrerCutPercentage = ($$.timer >= block.timestamp) ? 10 : 0;
            // this is the percentage the vendor will get if the execute buy using buyGamesFrom
            vendorCutPercentage = 10;
        }
        uint256 buyTax = calcFeeWithPrecision(price, buyTaxFee, precision);
        referrerCut = calcFeeWithPrecision(buyTax, referrerCutPercentage, 0);
        vendorCut = calcFeeWithPrecision(buyTax, vendorCutPercentage, 0);

        buyTax = buyTax - vendorCut - referrerCut;

        $.platformPool += buyTax;

        return (referrerCut, vendorCut);
    }

    /**
     * @custom:function-name claims
     * @param _claimInfo a list of data about the ticket to be claimed
     * @custom:sub-param `_claimInfo` - `ticketId` the Id of the winning ticket a user wants to claim
     * @custom:sub-param `_claimInfo` - `id` the id of the game to be claimed
     * @custom:sub-param `_claimInfo` - `tier` the tier of the game assigned with the prize value
     * @custom:sub-param `_claimInfo` - `messageHash` the hashed message using 
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))` as the message  parameter following
     * the signed data standard EIP-191
     * @custom:sub-param `_claimInfo` - `signature` the signature from an address with
     * the role of keccack256("VERIFIER_ROLE") and a message parameter of
     * `keccak256(abi.encodePacked(ticketOwner, gameId, tier))`
     * @param _date the draw date of the winning ticket
     * 
     * @custom:access-restrictions Ticket Owner, Valid Game Information, Not Locked
     * prevents claiming tickets owned by others and if the provided information is incorrect
     * 
     * @dev this function allows for claiming one or multiple winning games in the same draw date.
     */
    function claims(ClaimInfo[] calldata _claimInfo, DateType calldata _date) external nonReentrant isClaimNotLocked {
        
        address claimer = _msgSender();
        
        if(claimer == address(0)) revert CanNotBeZeroAddress();

        uint256 amountTotal = _claims(_claimInfo, _date, claimer);

        (bool success,) = payable(claimer).call{ value: amountTotal }("");
        require(success, "Failed To Send ETH!");
    }

    /**
     * @custom:function-name draw
     * @param _date the draw date
     * @param ball the lottery's winning numbers for the specified draw date 
     * @param _winnerCount the number of winners per tier
     * 
     * @custom:access-restrictions Draw Role
     * prevents accounts other than those who have Draw Role to call this function
     * 
     * @dev this function is used to publish the draw result on chain while also setting the
     * amount of prizes a win can claim according to their tier. this is also where the tax
     * distribution to the platform pool happens.
     */
    function draw(DateType calldata _date, LotteryNumbers calldata ball, WinnersPerTier calldata _winnerCount) external nonReentrant onlyRole(keccak256("DRAW_ROLE")) {
        
        uint256 _prizePool = prizePool();
        _draw(_date, ball, _winnerCount, _prizePool);

    }

    /**
     * @custom:function-nanme prizePool
     * 
     * @return uint256 the prize pool for the next draw in ETH
     * 
     * @dev this function returns the prize pool for the nearest draw date
     */
    function prizePool() public view returns(uint256) {
        PoolStorage storage $ = _getPoolStorage();
        return address(this).balance - $.platformPool - $.vendorPool - $.rewardPool.total;
    }

    /**
     * @custom:function-name withdrawExpiredRewards
     * 
     * @custom:access-restrictions Platform Wallet
     * prevents accounts other than the platform wallet from calling this function
     * 
     * @dev allows the platform wallet, a multisig wallet to withdraw the ETH balance
     * of unclaimed rewards from a specific draw date after 365 days have passed from that time
     */
    function withdrawExpiredRewards(DateType calldata _date) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        WalletStorage storage $ = _getWalletStorage();
        PoolStorage storage $$ = _getPoolStorage();
        
        address _platformWallet = $.PLATFORM_WALLET;
        // this is to make sure that the function will revert if 
        // the platform wallet is somehow became zeroAddress
        // when the contract has not been rennounced 
        if(_platformWallet == address(0)) revert CanNotBeZeroAddress();

        uint256 _drawDate = Date.getTimestamp(_date.month, _date.day, _date.year, DRAW_HOUR_IN_UTC, DRAW_MINUTE_IN_UTC, DRAW_SECOND_IN_UTC);

        uint256 currentTime = block.timestamp;

        if(currentTime < (_drawDate + 365 days)) revert NotYetExpired();
        
        uint256 expiredRewardTotal = $$.rewardPool.pool[_drawDate];

        $$.rewardPool.pool[_drawDate] = 0;
        $$.rewardPool.total -= expiredRewardTotal;

        emit Withdraw("Expired Rewards", expiredRewardTotal);

        (bool success,) = payable(_platformWallet).call{ value: expiredRewardTotal }("");
        require(success, "Failed To Send ETH!");
    } 

    /**
     * @custom:function-name withdrawPlatform
     * 
     * @custom:access-restrictions Platform Wallet
     * prevents accounts other than the platform wallet from calling this function
     * 
     * @dev allows the platform wallet, a multisig wallet to withdraw the ETH balance of the same
     * amount as the one in the platform pool
     */
    function withdrawPlatform() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        WalletStorage storage $ = _getWalletStorage();
        PoolStorage storage $$ = _getPoolStorage();

        uint256 platformPoolBalance = $$.platformPool;
        $$.platformPool = 0;

        address _platformWallet = $.PLATFORM_WALLET;
        // this is to make sure that the function will revert if 
        // the platform wallet is somehow became zeroAddress
        // when the contract has not been rennounced 
        if(_platformWallet == address(0)) revert CanNotBeZeroAddress();
        
        emit Withdraw("Platform Fee", platformPoolBalance);

        (bool success,) = payable(_platformWallet).call{ value: platformPoolBalance }("");
        require(success, "Failed To Send ETH!");
    }

    /**
     * @custom:function-name withdrawVendor
     * 
     * @custom:access-restrictions Platform Wallet
     * prevents accounts other than the platform wallet from calling this function
     * 
     * @dev allows the platform wallet, a multisig wallet to withdraw the ETH balance of the same
     * amount as the one in the vendor pool
     */
    function withdrawVendor() external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        WalletStorage storage $ = _getWalletStorage();
        PoolStorage storage $$ = _getPoolStorage();

        uint256 vendorPoolBalance = $$.vendorPool;
        $$.vendorPool = 0;

        address _platformWallet = $.PLATFORM_WALLET;
        // this is to make sure that the function will revert if 
        // the platform wallet is somehow became zeroAddress
        // when the contract has not been rennounced 
        if(_platformWallet == address(0)) revert CanNotBeZeroAddress();

        emit Withdraw("Vendor Pool", vendorPoolBalance);

        (bool success,) = payable(_platformWallet).call{ value: vendorPoolBalance }("");
        require(success, "Failed To Send ETH!");
    }

    /**
     * @custom:modifier-name hasETHBalance
     * @param _gameAmount amount of games
     * 
     * @dev this modifier is used in `buyGames` to check if the buyer has enough ETH
     * balance on their wallet
     */
    modifier hasETHBalance(uint256 _gameAmount){
        InformationStorage storage $ = _getInformationStorage();

        address _buyer = _msgSender();
        uint256 balance = _buyer.balance;
        uint256 price = $.gamePrice * _gameAmount;
        
        if(balance < price) revert InsufficientBalance();

        _;
    } 

}

contract PegaBallV1Implementation is PegaBallUpgradeable {

    /**
     * @dev _disableInitializers prevents future reinitializations
     * 
     * https://docs.openzeppelin.com/contracts/5.x/api/proxy#Initializable-_disableInitializers-- for more info
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @custom:function-name initialize
     * 
     * @param _PLATFORM_WALLET the platform wallet address (multi-sig)
     * @param _DRAW_WALLET the draw wallet address (used in  draw, lock)
     * @param _tax taxes in percentage along with the precision
     * @param _gamePrice the game price in ETH upon deployment
     * 
     * @dev this is used in palce of a constructor to initialize a proxy's state using this implemetation's logic
     */
    function initialize(address _PLATFORM_WALLET, address _DRAW_WALLET, Tax calldata _tax, uint256 _gamePrice) initializer external {

        __PegaBallUpgradeable_init(_PLATFORM_WALLET, _DRAW_WALLET, _tax, _gamePrice);

    }

    /**
     * @custom:function-name _authorizeUpgrade
     * 
     * @param newImplementation implementation address
     * 
     * @dev this is a function required by solidity and the openzeppelin UUPS contract
     * this is used to prevent unauthorized account to upgrade the contract
     */
    function _authorizeUpgrade(address newImplementation) internal onlyRole(UPGRADER_ROLE) override {}

}