/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library Math {
    function difference(uint256 from, uint256 to) internal pure returns (int256) {
        return abs(int256(from) - int256(to));
    }

    function abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function factorial(uint256 n) internal pure returns (uint256) {
        uint256 result = 1;
        for (uint256 i = 2; i <= n; i++) {
            result *= i;
        }
        return result;
    }
}