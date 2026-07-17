// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

interface IPoseidon5 {
    function poseidon(uint256[5] memory input) external pure returns (uint256);

    function poseidon(bytes32[5] memory input) external pure returns (bytes32);
}
