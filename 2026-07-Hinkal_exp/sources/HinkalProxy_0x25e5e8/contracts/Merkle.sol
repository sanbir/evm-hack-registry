// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./types/IPoseidon2.sol";
import "./MerkleBase.sol";

///@title Hinkal Merkle Tree
contract Merkle is MerkleBase {
    constructor(
        MerkleConstructorArgs memory constructorArgs
    ) MerkleBase(constructorArgs) {}

    function outputGas(uint256 index, uint256[] memory gasUsed) internal view {
        gasUsed[index] = gasleft();
    }

    ///@notice insert a single new leaf to Merkle Tree
    ///@param leaf value to be inserted
    ///@return index index of node inserted
    function insert(uint256 leaf) internal override returns (uint256) {
        uint256 newIndex = ++m_index;
        uint256 currentNodeIndex = newIndex - 1;

        require(m_index <= uint256(2) ** LEVELS, "Tree is full.");

        uint256 fullCount = newIndex - MINIMUM_INDEX; // number of inserted leaves
        uint256 twoPower = logarithm2(fullCount); // number of tree levels to be updated, (e.g. if 9 => 4 levels should be updated)

        uint256 prevHash = leaf;

        insertOne(currentNodeIndex, twoPower, prevHash);

        roots[rootIndex] = tree[twoPower]; // adding root to roots mapping
        rootIndex = (rootIndex + 1) % MAX_ROOT_NUMBER;
        return newIndex - 1;
    }

    function insertMany(
        uint256[] memory leaves
    ) internal returns (uint256[] memory insertedIndexes) {
        m_index += leaves.length;
        uint256 newIndex = m_index;
        uint256 currentNodeIndex = newIndex - leaves.length;

        require(m_index <= uint256(2) ** LEVELS, "Tree is full.");

        insertedIndexes = new uint256[](leaves.length);
        for (uint256 i = 0; i < insertedIndexes.length; i++) {
            insertedIndexes[i] = currentNodeIndex + i;
        }

        uint256[][] memory sortedLeaves = sortInPairs(leaves, currentNodeIndex);

        uint256 fullCount = newIndex - MINIMUM_INDEX; // number of inserted leaves
        uint256 twoPower = logarithm2(fullCount); // number of tree levels to be updated, (e.g. if 9 => 4 levels should be updated)

        for (uint256 i = 0; i < sortedLeaves.length; i++) {
            if (sortedLeaves[i].length == 1)
                insertOne(currentNodeIndex++, twoPower, sortedLeaves[i][0]);
            else {
                insertTwo(
                    sortedLeaves[i][0],
                    sortedLeaves[i][1],
                    currentNodeIndex,
                    twoPower
                );
                currentNodeIndex += 2;
            }
        }

        roots[rootIndex] = tree[twoPower]; // adding root to roots mapping
        rootIndex = (rootIndex + 1) % MAX_ROOT_NUMBER;
    }

    ///@notice insert single value and update Merkle Tree
    ///@param currentNodeIndex Index of the last node before insertion
    ///@param twoPower Nodes in Merkle Tree that must be updated
    ///@param prevHash node to be inserted
    function insertOne(
        uint256 currentNodeIndex,
        uint256 twoPower,
        uint256 prevHash
    ) internal {
        for (uint256 i = 0; i <= twoPower; i++) {
            if (currentNodeIndex % 2 == 0 || currentNodeIndex == 1) {
                tree[i] = prevHash;
                if (i != twoPower) prevHash = hash2(prevHash, 0);
            } else {
                prevHash = hash2(tree[i], prevHash);
            }
            currentNodeIndex /= 2;
        }
    }

    function insertTwo(
        uint256 left,
        uint256 right,
        uint256 currentNodeIndex,
        uint256 twoPower
    ) internal {
        uint256 prevHash = hash2(left, right);
        currentNodeIndex /= 2; // we are starting from i = 1, so we need one iteration

        for (uint256 i = 1; i <= twoPower; i++) {
            if (currentNodeIndex % 2 == 0 || currentNodeIndex == 1) {
                tree[i] = prevHash;
                if (i != twoPower) prevHash = hash2(prevHash, 0);
            } else {
                prevHash = hash2(tree[i], prevHash);
            }
            currentNodeIndex /= 2;
        }
    }

    ///@notice Sort leaf nodes in pairs of left and right nodes.
    ///@param leaves leaves to be sorted
    ///@param currentNodeIndex Index of the last node to be inserted
    ///@return sortedLeaves leaves sorted in pairs of left and right
    function sortInPairs(
        uint256[] memory leaves,
        uint256 currentNodeIndex
    ) internal pure returns (uint256[][] memory sortedLeaves) {
        uint leavesLength = leaves.length;
        bool firstLeafIfRight = currentNodeIndex % 2 != 0;

        uint256 firstElement = firstLeafIfRight ? 1 : 0;
        uint256 netElements = leavesLength - firstElement;

        uint256 lengthWithoutFirst = (netElements % 2 == 0)
            ? netElements / 2
            : (netElements + 1) / 2;

        sortedLeaves = new uint256[][](firstElement + lengthWithoutFirst);

        if (firstLeafIfRight) {
            uint256[] memory first = new uint256[](1);
            first[0] = leaves[0];
            sortedLeaves[0] = first;
        }

        uint arrIndex = firstLeafIfRight ? 1 : 0;
        uint sortedArrayIndex = arrIndex;
        while (arrIndex < leavesLength) {
            uint256[] memory arr;
            if (arrIndex + 1 < leavesLength) {
                arr = new uint256[](2);
                arr[0] = leaves[arrIndex];
                arr[1] = leaves[++arrIndex];
            } else {
                arr = new uint256[](1);
                arr[0] = leaves[arrIndex];
            }
            sortedLeaves[sortedArrayIndex++] = arr;
            ++arrIndex;
        }
    }
}
