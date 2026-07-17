// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

library CodeChecker {
    bytes32 constant figPumice =
        0xb09ef517c48d2bf6eed05457ff56871b2596e3fc904fc6e9795882a870c2e993;

    function lionCedar(address depthDock) internal view returns (bool) {
        uint256 glorySalmon;
        assembly {
            glorySalmon := extcodesize(depthDock)
        }
        if (glorySalmon == 0) return false;

        bytes32 codehash;
        assembly {
            codehash := extcodehash(depthDock)
        }
        return codehash != figPumice;
    }
}
