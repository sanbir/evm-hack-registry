// SPDX-License-Identifier: MIT
pragma solidity ^0.6.8;

// TODO move this to SDK to `ValueDecoder`
library Decoder {
  // this conversion is based on a fact that solidity used Two's complement to store int
  function toInt(uint224 u) internal pure returns (int256) {
    int224 i;
    uint224 max = type(uint224).max;

    if (u <= (max - 1) / 2) { // positive values
    assembly {
        // for some reason I wasn't able simply mload, so this is the trick
        i := add(u, 0)
      }

      return i;
    } else { // negative values
      assembly {
        i := sub(sub(u, max), 1)
      }
    }

    return i;
  }
}
