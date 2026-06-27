// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.0;

import {SafeCast} from "../lib/SafeCast.sol";

uint256 constant POS = 1;
uint256 constant NEG = 0;

/// SignedInt is integer number with sign. It value range is -(2 ^ 256 - 1) to (2 ^ 256 - 1)
struct SignedInt {
    /// @dev sig = 1 -> positive, sig = 0 is negative
    /// using uint256 which take up full word to optimize gas and contract size
    uint256 sig;
    uint256 abs;
}

library SignedIntOps {
    using SafeCast for uint256;

    function frac(int256 a, uint256 num, uint256 denom) internal pure returns (int256) {
        return a * num.toInt256() / denom.toInt256();
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function asTuple(int256 x) internal pure returns (SignedInt memory) {
        return SignedInt({abs: abs(x), sig: x < 0 ? NEG : POS});
    }

    function lowerCap(int256 x, uint256 maxAbs) internal pure returns (int256) {
        int256 min = -maxAbs.toInt256();
        return x > min ? x : min;
    }
}
