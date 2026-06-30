// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library SimpleRNG {
    /// @param salt The seed for the random value(s)
    /// @param n The number of random values to generate
    /// @param mod The maximum value of each random number; should be below 320
    /// @return results The RNG values
    function getRNG(uint256 salt, uint256 n, uint256 mod)
        external
        pure
        returns(uint256[] memory results)
    {
        results = new uint256[](n);
        for (uint256 i = 0; i < n;) {
            results[i] = (salt + i) % mod;

            unchecked {
              i++;
            }
        }
    }
}