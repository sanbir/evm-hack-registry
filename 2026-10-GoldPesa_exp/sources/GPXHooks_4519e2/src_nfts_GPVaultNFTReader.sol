// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BlobReaderMulti.sol";

contract GPVaultNFTReader is BlobReaderMulti {
    constructor(address[][] memory _blobs) BlobReaderMulti(_blobs) {}

    function read(
        string memory arg0,string memory arg1,string memory arg2,string memory arg3,string memory arg4
    ) public view returns (bytes memory svg) {
        return bytes.concat(read(0, 3219), bytes(arg0),read(1, 182), bytes(arg1),read(2, 644), bytes(arg2),read(3, 183), bytes(arg3),read(4, 414), bytes(arg4),read(5, 45668));
    }
}
    