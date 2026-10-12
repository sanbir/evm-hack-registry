// src/BlobReaderMulti.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract BlobReaderMulti {
    address[][] private blobs;

    constructor(address[][] memory _blobs) {
        blobs = _blobs;
    }

    function read(uint256 index, uint256 length) internal view returns (bytes memory svg) {
        svg = new bytes(length);
        uint256 offset = 0;
        for (uint256 i = 0; i < blobs[index].length; i++) {
            bytes memory part = blobs[index][i].code;
            for (uint256 j = 0; j < part.length; j++) {
                svg[offset++] = part[j];
            }
        }
    }
}
