// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./types/IPoseidon2.sol";
import "./types/IPoseidon4.sol";
import "./types/IPoseidon5.sol";
import "./types/IMerkle.sol";

abstract contract MerkleBase is IMerkle {
    using Math for uint256;

    // states
    mapping(uint256 => uint256) public tree;
    mapping(uint256 => uint256) public roots;
    uint256 public m_index; // current index of the tree
    uint256 public rootIndex = 0;
    // constants
    uint256 immutable LEVELS; // deepness of tree
    uint256 constant MAX_ROOT_NUMBER = 200;
    uint256 immutable MINIMUM_INDEX;
    IPoseidon2 public immutable poseidon2; // hashing
    IPoseidon4 public immutable poseidon4; // hashing
    IPoseidon5 public immutable poseidon5;

    // please see deployment scripts to understand how to create and instance of Poseidon contract
    constructor(MerkleConstructorArgs memory constructorArgs) {
        LEVELS = constructorArgs.levels;
        m_index = 2 ** (LEVELS - 1);
        MINIMUM_INDEX = 2 ** (LEVELS - 1);
        poseidon2 = IPoseidon2(constructorArgs.poseidon2);
        poseidon4 = IPoseidon4(constructorArgs.poseidon4);
        poseidon5 = IPoseidon5(constructorArgs.poseidon5);
    }

    function hash2(
        uint256 a,
        uint256 b
    ) public view returns (uint256 poseidonHash) {
        poseidonHash = poseidon2.poseidon([a, b]);
    }

    function hash4(
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3
    ) public view returns (uint256 poseidonHash) {
        poseidonHash = poseidon4.poseidon([a0, a1, a2, a3]);
    }

    function hash5(
        uint256 a0,
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 a4
    ) public view returns (uint256 poseidonHash) {
        poseidonHash = poseidon5.poseidon([a0, a1, a2, a3, a4]);
    }

    function insert(uint256 leaf) internal virtual returns (uint256);

    function getRootHash() public view returns (uint256) {
        return roots[rootIndex > 0 ? rootIndex - 1 : MAX_ROOT_NUMBER - 1];
    }

    function rootHashExists(uint256 _root) public view returns (bool) {
        uint256 i = rootIndex; // latest root hash
        do {
            if (i == 0) {
                i = MAX_ROOT_NUMBER;
            }
            i--;
            if (_root == roots[i]) {
                return true;
            }
        } while (i != rootIndex);
        return false;
    }

    ///@notice logarithm of x with base 2.
    ///@notice instead of rounding down, this function rounds up.
    ///@param x operand
    ///@return y logarithm base 2 of input
    function logarithm2(uint256 x) public pure returns (uint256 y) {
        y = Math.log2(x, Math.Rounding.Up);
    }
}
