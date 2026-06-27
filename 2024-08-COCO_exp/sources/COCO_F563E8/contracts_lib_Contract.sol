// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

contract Contract {
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
