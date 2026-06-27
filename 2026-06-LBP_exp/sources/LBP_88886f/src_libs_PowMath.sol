// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {UD60x18, ud, pow} from "@prb/math/src/UD60x18.sol";

/// @title PowMath
/// @notice Computes `0.998^t` for emission decay using PRBMath's UD60x18 fixed-point type.
library PowMath {
    /// @dev 0.998 encoded in UD60x18 (1e18 scale).
    UD60x18 internal constant BASE_998 = UD60x18.wrap(998e15);

    /// @dev Beyond this exponent the result rounds to zero in UD60x18 and PRBMath's `pow`
    ///      would waste gas; short-circuit to keep behavior deterministic.
    uint256 internal constant MAX_T = 10_000;

    /**
     * @notice Computes `0.998^t`, where `t` is a whole-day exponent.
     * @param t Number of days elapsed since trading opened.
     * @return `0.998^t` scaled by 1e18 (UD60x18 raw value).
     */
    function pow998(uint256 t) internal pure returns (uint256) {
        if (t == 0) return 1e18;
        if (t > MAX_T) return 0;

        UD60x18 exponent = ud(t * 1e18);
        UD60x18 result = pow(BASE_998, exponent);
        return result.unwrap();
    }
}
