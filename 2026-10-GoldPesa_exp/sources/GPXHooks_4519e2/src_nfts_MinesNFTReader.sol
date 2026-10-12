// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BlobReaderMulti.sol";

contract MinesNFTReader is BlobReaderMulti {
    constructor(address[][] memory _blobs) BlobReaderMulti(_blobs) {}

    function read(
        string memory arg0,string memory arg1,string memory arg2,string memory arg3
    ) public view returns (bytes memory svg) {
        return bytes.concat(read(0, 2005), bytes(arg0),read(1, 37), bytes(arg1),read(2, 41), bytes(arg2),read(3, 398028), bytes(arg3),read(4, 25046));
    }
}
    