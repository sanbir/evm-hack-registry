// SPDX-License-Identifier: GPL-3.0-or-later
// Vendored from @balancer-labs/v2-solidity-utils/contracts/math/Math.sol
// (migrated to ^0.8.0; original 0.7.x checked-arithmetic semantics preserved)

pragma solidity ^0.8.0;

import "../helpers/BalancerErrors.sol";

/* solhint-disable */

/**
 * @dev Library for basic but unchecked math operations: these operations would otherwise revert on overflow/underflow
 * in 0.8.x, but the Balancer originals relied on hand-written overflow checks (returning BAL# error codes). To preserve
 * the exact revert codes and behavior expected by StableMath, we use `unchecked` blocks plus the original checks.
 */
library Math {
    /**
     * @dev Returns the absolute value of a signed integer.
     */
    function abs(int256 a) internal pure returns (uint256) {
        unchecked {
            return a > 0 ? uint256(a) : uint256(-a);
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers of 256 bits, reverting on overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            _require(c >= a, Errors.ADD_OVERFLOW);
            return c;
        }
    }

    /**
     * @dev Returns the addition of two signed integers, reverting on overflow.
     */
    function add(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a + b;
            _require((b >= 0 && c >= a) || (b < 0 && c < a), Errors.ADD_OVERFLOW);
            return c;
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers of 256 bits, reverting on overflow.
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b <= a, Errors.SUB_OVERFLOW);
            uint256 c = a - b;
            return c;
        }
    }

    /**
     * @dev Returns the subtraction of two signed integers, reverting on overflow.
     */
    function sub(int256 a, int256 b) internal pure returns (int256) {
        unchecked {
            int256 c = a - b;
            _require((b >= 0 && c <= a) || (b < 0 && c > a), Errors.SUB_OVERFLOW);
            return c;
        }
    }

    /**
     * @dev Returns the largest of two numbers of 256 bits.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    /**
     * @dev Returns the smallest of two numbers of 256 bits.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a * b;
            _require(a == 0 || c / a == b, Errors.MUL_OVERFLOW);
            return c;
        }
    }

    function div(
        uint256 a,
        uint256 b,
        bool roundUp
    ) internal pure returns (uint256) {
        return roundUp ? divUp(a, b) : divDown(a, b);
    }

    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);
            return a / b;
        }
    }

    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            _require(b != 0, Errors.ZERO_DIVISION);

            if (a == 0) {
                return 0;
            } else {
                return 1 + (a - 1) / b;
            }
        }
    }
}
