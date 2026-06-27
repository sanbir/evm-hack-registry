// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
// https://github.com/ethereum/solidity-examples/blob/master/docs/bits/Bits.md
library Bits {
    uint constant internal ONE = uint(1);

    // Sets the bit at the given 'index' in 'self' to '1'.
    // Returns the modified value.
    function setBit(uint self, uint8 index) internal pure returns (uint) {
        return self | ONE << index;
    }

    // Sets the bit at the given 'index' in 'self' to '0'.
    // Returns the modified value.
    function clearBit(uint self, uint8 index) internal pure returns (uint) {
        return self & ~(ONE << index);
    }

    function setOrClearBit(uint self, uint8 index, bool b) internal pure returns (uint) {
        if (b) {
            return self | ONE << index;
        } else {
            return self & ~(ONE << index);
        }
    }

    // Check if the bit at the given 'index' in 'self' is set.
    // Returns:
    //  'true' - if the value of the bit is '1'
    //  'false' - if the value of the bit is '0'
    function bitSet(uint self, uint8 index) internal pure returns (bool) {
        return self >> index & 1 == 1;
    }
}
