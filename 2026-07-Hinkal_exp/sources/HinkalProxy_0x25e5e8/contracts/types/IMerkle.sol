// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IMerkle {

    struct MerkleConstructorArgs {
        uint128 levels;
        address poseidon2;
        address poseidon4;
        address poseidon5;
    }

    function hash2(uint256 a, uint256 b) external view returns (uint256);

    function getRootHash() external view returns (uint256);

    function rootHashExists(uint256 _root) external view returns (bool);

    function logarithm2(uint256 x) external pure returns (uint256);
}
