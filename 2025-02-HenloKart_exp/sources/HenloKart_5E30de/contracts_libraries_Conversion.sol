/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library Conversion {
    function convertToBytes(int256 value) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(value));
    }
    
    function convertToInt256(bytes32 value) internal pure returns (int256) {
        return abi.decode(abi.encodePacked(value), (int256));
    }
}