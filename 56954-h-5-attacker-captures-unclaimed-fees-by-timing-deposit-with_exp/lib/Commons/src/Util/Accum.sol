// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

type Accum is uint256;

/// Type accum is an accumulator variable that can overflow and wrap around.
/// It is used for values that grow in size but can't grow so fast that a user could reasonably wrap around.
/// For example a user might collect fees over the lifetime of their positions. 2^256 is so large
/// that it is practically impossible for them to wrap all the way around.
/// However we want to do this safely so we wrap this in a type that doesn't allow subtraction.
library AccumImpl {
    /// Construct accumulator from a uint value
    function from(uint256 num) public pure returns (Accum) {
        return Accum.wrap(num);
    }

    /// Construct accumulator from a signed int.
    function from(int256 num) public pure returns (Accum) {
        // We can just cast to a uint because all ints wrap around the same way which
        // is the only property we need here.
        return Accum.wrap(uint256(num));
    }

    /// Add to the accumulator.
    /// @param addend the value being added
    /// @return acc The new accumulated value
    function add(Accum self, uint256 addend) internal pure returns (Accum acc) {
        unchecked {
            return Accum.wrap(Accum.unwrap(self) + addend);
        }
    }

    /// Calc the difference between self and other. This tells us how much has accumulated.
    /// @param other the value being subtracted from the accumulation
    /// @return difference The difference between other and self which is always positive.
    function diff(Accum self, Accum other) internal pure returns (uint256) {
        unchecked { // underflow is okay
            return Accum.unwrap(self) - Accum.unwrap(other);
        }
    }

    /// Also calculates the difference between self and other, telling us the total accumlation.
    /// @return diffAccum The difference between self and other but as an Accum
    function diffAccum(Accum self, Accum other) internal pure returns (Accum) {
        return Accum.wrap(diff(self, other));
    }
}
