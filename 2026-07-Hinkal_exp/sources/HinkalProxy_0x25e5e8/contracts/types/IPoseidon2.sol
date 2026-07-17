// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

interface IPoseidon2 {
    function poseidon(uint256[2] memory input) external pure returns (uint256);

    function poseidon(bytes32[2] memory input) external pure returns (bytes32);
}
