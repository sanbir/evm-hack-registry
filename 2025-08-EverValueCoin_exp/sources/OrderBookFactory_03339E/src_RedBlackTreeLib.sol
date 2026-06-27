// SPDX-License-Identifier: MIT
/*
* This file contains code modified from BokkyPooBahsRedBlackTreeLibrary.sol
* from BokkyPooBahsRedBlackTreeLibrary (https://github.com/bokkypoobah/BokkyPooBahsRedBlackTreeLibrary)
* Original work Copyright (c) 2020 BokkyPooBah / Bok Consulting Pty Ltd
* Modified work Copyright (c) 2024 Diego Leal / Angel García / Artech Software
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/
pragma solidity 0.8.26;

/**
 * @title Red-Black Tree Implementation for Solidity
 * @dev This contract implements a red-black tree, which is a self-balancing binary search tree.
 *      It is designed to be used for managing order books or any other sorted data structures efficiently.
 */
library RedBlackTreeLib {
    /* Errors */

    error RBT__StartingValueCannotBeZero();
    error RBT__ValuesDoesNotExist();
    error RBT__NodeDoesNotExist();
    error RBT__ValueToInsertCannotBeZero();
    error RBT__ValueCannotBeZero();

    /**
     *  @notice Represents an empty value in the tree; it is used to denote nodes that do not exist or are empty.
     */
    uint256 private constant EMPTY = 0;

    /**
     *  @notice Struct representing a node in the Red-Black Tree.
     */
    struct Node {
        uint256 parent; // Parent node
        uint256 left; // Left child node
        uint256 right; // Right child node
        bool red; // Color of the node, true if red, false if black
    }

    /**
     *  @notice Struct representing the entire Red-Black Tree
     */
    struct Tree {
        uint256 root; // Root node of the tree
        mapping(uint256 => Node) nodes; // Mapping of keys to their corresponding nodes
    }

    // Utility functions

    /**
     * @dev Checks if a node with a given value exists in the Red-Black tree.
     *
     * This function determines whether a node with the specified value is present
     * in the tree by checking the following:
     *
     * 1. If the provided `value` is `EMPTY` (commonly `0`), it returns `false`
     *    indicating the node cannot exist.
     * 2. If the `value` matches the root of the tree, it returns `true` as the root
     *    node is always considered to exist.
     * 3. Otherwise, it checks if the node has a parent that is not `EMPTY`. If the
     *    node has a valid parent, it implies the node is present in the tree.
     *
     * To optimize gas usage, the function stores the node reference in a local
     * variable to avoid repeated storage access.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The value of the node to check for existence.
     *
     * @return _exists A boolean indicating whether the node with the specified
     *         value exists in the tree.
     */
    function exists(Tree storage self, uint256 value) internal view returns (bool _exists) {
        if (value == EMPTY) return false;
        if (value == self.root) return true;

        return self.nodes[value].parent != EMPTY;
    }

    /**
     * @dev Retrieves various attributes of a node in the Red-Black tree.
     *
     * This function is used to access the key properties of a node identified by its `value`
     * in the Red-Black tree. It ensures that the node exists before accessing its properties.
     *
     * Steps performed:
     *
     * 1. Validates that the node with the specified `value` exists in the tree using `require`.
     *    If the node does not exist, the function reverts with an error.
     * 2. Accesses the node's properties including its parent, left and right children,
     *    whether it's red, the number of keys, and a custom count.
     * 3. Returns the following attributes of the node:
     *    - `_parent`: The value of the parent node.
     *    - `_left`: The value of the left child node.
     *    - `_right`: The value of the right child node.
     *    - `_red`: A boolean indicating whether the node is red.
     *    - `countTotalOrders`: The number orders in node.
     *    - `countValueOrders`: The sum of value in total orders.
     *
     * @param self A reference to the `Tree` struct in storage containing all nodes and the root.
     * @param value The value of the node whose attributes are to be retrieved.
     *
     */
    function getNode(Tree storage self, uint256 value) internal view returns (Node storage) {
        if (!exists(self, value)) revert RBT__ValuesDoesNotExist();
        return self.nodes[value];
    }

    // Tree traversal

    /**
     * @dev Retrieves the value of the leftmost node in the Red-Black tree.
     *
     * This function returns the smallest value in the tree, which is the
     * leftmost node when traversing from the root. It starts from the root node
     * and continually moves to the left child until it reaches a node with no
     * left child. The function performs the following steps:
     *
     * 1. Initializes `_value` with the root of the tree.
     * 2. Checks if the tree is empty (i.e., the root is `EMPTY`). If so, returns `0`.
     * 3. If the tree is not empty, it enters a loop to find the leftmost node:
     *    - Updates `_value` to the left child of the current node.
     *    - Updates the `currentNode` to the newly found left child node.
     * 4. Continues this process until a node with no left child is reached.
     * 5. Returns the value of the leftmost node found.
     *
     * @param self A reference to the `Tree` struct in storage. This struct
     *        contains the nodes and root of the Red-Black tree.
     *
     * @return _value The value of the leftmost node in the tree. If the tree is
     *         empty, it returns `0`.
     */
    function first(Tree storage self) internal view returns (uint256 _value) {
        _value = self.root;
        if (_value == EMPTY) return 0;
        Node storage currentNode = self.nodes[_value];
        while (currentNode.left != EMPTY) {
            _value = currentNode.left;
            currentNode = self.nodes[_value];
        }
    }

    /**
     * @dev Retrieves the value of the rightmost node in the Red-Black tree.
     *
     * This function returns the largest value in the tree, which is the
     * rightmost node when traversing from the root. It starts from the root node
     * and continually moves to the right child until it reaches a node with no
     * right child. The function performs the following steps:
     *
     * 1. Initializes `_value` with the root of the tree.
     * 2. Checks if the tree is empty (i.e., the root is `EMPTY`). If so, returns `0`.
     * 3. If the tree is not empty, it enters a loop to find the rightmost node:
     *    - Updates `_value` to the right child of the current node.
     *    - Continues this process until a node with no right child is reached.
     * 4. Returns the value of the rightmost node found.
     *
     * @param self A reference to the `Tree` struct in storage. This struct
     *        contains the nodes and root of the Red-Black tree.
     *
     * @return _value The value of the rightmost node in the tree. If the tree is
     *         empty, it returns `0`.
     */
    function last(Tree storage self) internal view returns (uint256 _value) {
        _value = self.root;
        if (_value == EMPTY) return 0;
        Node storage currentNode = self.nodes[_value];
        while (currentNode.right != EMPTY) {
            _value = currentNode.right;
            currentNode = self.nodes[_value]; // Avoid repeated access to `self.nodes[_value]`
        }
    }

    /**
     * @dev Finds the successor of a given node in the Red-Black tree.
     *
     * The successor of a node is the node with the smallest value that is greater than
     * the given node's value. The function performs the following steps:
     *
     * 1. Ensures the provided `value` is not `EMPTY`. If it is, the function reverts with
     *    an error message.
     * 2. Checks if the given node has a right child. If it does, the successor is the
     *    minimum value in the right subtree.
     * 3. If the node has no right child, it searches among the ancestors of the node.
     *    - Moves up to the parent node until it finds a node that is a left child of its
     *      parent or reaches the root.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The value of the node for which the successor is to be found.
     *
     * @return _cursor The value of the successor node. If there is no successor,
     *         it returns `EMPTY`.
     */
    function next(Tree storage self, uint256 value) internal view returns (uint256 _cursor) {
        if (value == EMPTY) revert RBT__StartingValueCannotBeZero();
        Node storage currentNode = self.nodes[value];
        if (currentNode.right != EMPTY) {
            // If the node has a right child, find the minimum value in the right subtree
            _cursor = treeMinimum(self, currentNode.right);
        } else {
            // If no right child, traverse up the tree until we find a parent that is a left child
            _cursor = currentNode.parent;
            while (_cursor != EMPTY && value == self.nodes[_cursor].right) {
                value = _cursor;
                _cursor = self.nodes[_cursor].parent;
            }
        }
    }

    /**
     * @dev Finds the predecessor of a given node in the Red-Black tree.
     *
     * The predecessor of a node is the node with the largest value that is smaller than
     * the given node's value. The function performs the following steps:
     *
     * 1. Ensures the provided `value` is not `EMPTY`. If it is, the function reverts with
     *    an error message.
     * 2. Checks if the given node has a left child. If it does, the predecessor is the
     *    maximum value in the left subtree.
     * 3. If the node has no left child, it searches among the ancestors of the node.
     *    - Moves up to the parent node until it finds a node that is a right child of its
     *      parent or reaches the root.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The value of the node for which the predecessor is to be found.
     *
     * @return _cursor The value of the predecessor node. If there is no predecessor,
     *         it returns `EMPTY`.
     */
    function prev(Tree storage self, uint256 value) internal view returns (uint256 _cursor) {
        if (value == EMPTY) revert RBT__StartingValueCannotBeZero();
        Node storage currentNode = self.nodes[value];
        if (currentNode.left != EMPTY) {
            // If the node has a left child, find the maximum value in the left subtree
            _cursor = treeMaximum(self, currentNode.left);
        } else {
            // If no left child, traverse up the tree until we find a parent that is a right child
            _cursor = currentNode.parent;
            while (_cursor != EMPTY && value == self.nodes[_cursor].left) {
                value = _cursor;
                _cursor = self.nodes[_cursor].parent;
            }
        }
    }

    // Tree modification

    /**
     * @dev Inserts a new node with the given value and key into the Red-Black tree.
     *
     * This function adds a node to the tree, maintaining the Red-Black properties. The process follows these steps:
     *
     * 1. Verifies that the `value` is not `EMPTY`. If it is, the function reverts.
     * 2. Checks that the key-value pair does not already exist in the tree. If it does, the function reverts.
     * 3. Starts from the root and traverses the tree to find the appropriate insertion point.
     *    - Updates the `cursor` as it moves through the tree.
     *    - Increments the count of nodes in the subtrees to maintain correct statistics.
     * 4. Once the correct position is found, a new node is created, and its parent, left, and right pointers are set.
     *    - The node is colored red by default.
     * 5. The function then fixes up the tree to maintain the Red-Black properties.
     *
     * @param self A reference to the `Tree` struct in storage that contains the nodes and root of the Red-Black tree.
     * @param value The value of the node to be inserted into the tree.
     */
    function insert(Tree storage self, uint256 value) internal {
        if (value == EMPTY) revert RBT__ValueToInsertCannotBeZero();
        if (exists(self, value)) return;

        uint256 cursor;
        uint256 probe = self.root;
        // Find the appropriate position to insert the new node
        while (probe != EMPTY) {
            cursor = probe;
            if (value < probe) {
                probe = self.nodes[probe].left;
            } else if (value > probe) {
                probe = self.nodes[probe].right;
            }
        }
        // Find the appropriate position to insert the new node
        Node storage nValue = self.nodes[value];
        nValue.parent = cursor;
        nValue.left = EMPTY;
        nValue.right = EMPTY;
        nValue.red = true;
        // Insert the new node into the tree
        if (cursor == EMPTY) {
            self.root = value;
        } else if (value < cursor) {
            self.nodes[cursor].left = value;
        } else {
            self.nodes[cursor].right = value;
        }
        // Rebalance the tree to maintain Red-Black properties
        insertFixup(self, value);
    }

    /**
     * @dev Removes a key from a node in the Red-Black tree.
     *
     * This function performs the following steps:
     *
     * 1. Ensures that the value to delete is not `EMPTY` and that the key exists in the node.
     * 2. Removes the key from the node's keys array.
     * 3. If the node has no keys left, it finds a replacement node and updates the tree:
     *    - If the node has at most one child, it directly replaces the node.
     *    - If the node has two children, it finds the successor (smallest node in the right subtree) to replace it.
     * 4. Adjusts the tree structure to maintain Red-Black properties.
     * 5. Deletes the old node and updates the tree structure accordingly.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The value identifying the node where the key is to be removed.
     */
    function remove(Tree storage self, uint256 value) internal {
        // Ensure the value and key exist
        if (value == EMPTY) revert RBT__ValueCannotBeZero();
        if (!exists(self, value)) revert RBT__NodeDoesNotExist();
        // Reference to the node to be removed
        Node storage nValue = self.nodes[value];

        uint256 probe;
        uint256 cursor;

        // Node has no keys left, handle its removal

        // Determine the node to be removed (cursor)
        if (nValue.left == EMPTY || nValue.right == EMPTY) {
            cursor = value;
        } else {
            // Find the in-order successor if the node has two children
            cursor = nValue.right;
            while (self.nodes[cursor].left != EMPTY) {
                cursor = self.nodes[cursor].left;
            }
        }

        // Set probe to the child of cursor (or EMPTY if no child)
        probe = self.nodes[cursor].left != EMPTY ? self.nodes[cursor].left : self.nodes[cursor].right;

        uint256 cursorParent = self.nodes[cursor].parent;
        self.nodes[probe].parent = cursorParent;

        // Update parent links
        if (cursorParent != EMPTY) {
            if (cursor == self.nodes[cursorParent].left) {
                self.nodes[cursorParent].left = probe;
            } else {
                self.nodes[cursorParent].right = probe;
            }
        } else {
            self.root = probe;
        }

        // Determine if fixup is needed
        bool cursorWasRed = self.nodes[cursor].red;

        // Handle case where cursor is not the value node
        if (cursor != value) {
            replaceParent(self, cursor, value);
            self.nodes[cursor].left = nValue.left;
            self.nodes[self.nodes[cursor].left].parent = cursor;
            self.nodes[cursor].right = nValue.right;
            self.nodes[self.nodes[cursor].right].parent = cursor;
            self.nodes[cursor].red = nValue.red;
            (cursor, value) = (value, cursor);
        }

        // Fix Red-Black tree properties
        if (!cursorWasRed) {
            removeFixup(self, probe);
        }

        // Delete the old node
        delete self.nodes[cursor];
    }

    // Helper functions

    /**
     * @dev Finds the minimum value node in the Red-Black tree starting from a given node.
     *
     * This function traverses the tree starting from the node identified by `value`,
     * and continually moves to the left child until it reaches the leftmost node.
     * The leftmost node is the one with the smallest value in the subtree.
     *
     * The function performs the following steps:
     *
     * 1. Initializes `value` as the starting node.
     * 2. Enters a loop that continues as long as the current node has a left child.
     *    - Updates `value` to the left child of the current node.
     * 3. When a node with no left child is found, the function returns the value
     *    of that node, as it is the minimum in the subtree.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The starting node from which to search for the minimum value.
     *
     * @return The value of the minimum node in the subtree. If the subtree is empty,
     *         it returns `EMPTY`.
     */
    function treeMinimum(Tree storage self, uint256 value) private view returns (uint256) {
        while (self.nodes[value].left != EMPTY) {
            value = self.nodes[value].left;
        }
        return value;
    }

    /**
     * @dev Finds the maximum value node in the Red-Black tree starting from a given node.
     *
     * This function traverses the tree starting from the node identified by `value`,
     * and continually moves to the right child until it reaches the rightmost node.
     * The rightmost node is the one with the largest value in the subtree.
     *
     * The function performs the following steps:
     *
     * 1. Initializes `value` as the starting node.
     * 2. Enters a loop that continues as long as the current node has a right child.
     *    - Updates `value` to the right child of the current node.
     * 3. When a node with no right child is found, the function returns the value
     *    of that node, as it is the maximum in the subtree.
     *
     * @param self A reference to the `Tree` struct in storage, which contains the
     *        nodes and root of the Red-Black tree.
     * @param value The starting node from which to search for the maximum value.
     *
     * @return The value of the maximum node in the subtree. If the subtree is empty,
     *         it returns `EMPTY`.
     */
    function treeMaximum(Tree storage self, uint256 value) internal view returns (uint256) {
        while (self.nodes[value].right != EMPTY) {
            value = self.nodes[value].right;
        }
        return value;
    }

    /**
     * @dev Performs a left rotation on a node in the Red-Black tree.
     *
     * A left rotation is a fundamental operation in balancing a Red-Black tree.
     * It repositions the nodes to ensure the tree remains balanced after insertion
     * or deletion operations. The function does the following:
     *
     * 1. Identifies the right child (`cursor`) of the node (`value`) to be rotated.
     * 2. Updates the right child of `value` to the left child of `cursor`.
     * 3. Updates the parent of the left child of `cursor` (if it exists) to be `value`.
     * 4. Repositions `cursor` as the parent of `value` and updates the relevant pointers.
     * 5. If `value` was the root, `cursor` becomes the new root.
     * 6. Recalculates the `count` property for `value` and `cursor` to maintain accurate
     *    node counts, optimizing the process by reducing redundant calculations.
     *
     * @param self A reference to the `Tree` struct in storage, containing the nodes
     *        and root of the Red-Black tree.
     * @param value The value of the node that needs to be rotated to the left.
     */
    function rotateLeft(Tree storage self, uint256 value) private {
        Node storage valueNode = self.nodes[value];
        uint256 cursor = valueNode.right;
        Node storage cursorNode = self.nodes[cursor];
        uint256 parent = valueNode.parent;
        uint256 cursorLeft = cursorNode.left;

        valueNode.right = cursorLeft;
        if (cursorLeft != EMPTY) {
            self.nodes[cursorLeft].parent = value;
        }

        cursorNode.parent = parent;
        if (parent == EMPTY) {
            self.root = cursor;
        } else {
            Node storage parentNode = self.nodes[parent];
            if (value == parentNode.left) {
                parentNode.left = cursor;
            } else {
                parentNode.right = cursor;
            }
        }

        cursorNode.left = value;
        valueNode.parent = cursor;
    }

    /**
     * @dev Performs a right rotation on the node identified by `value` within a Red-Black tree.
     *
     * A right rotation in a Red-Black tree is used to maintain the tree's balanced structure.
     * In a right rotation:
     * - The left child of the node (`cursor`) becomes the new root of the subtree.
     * - The original node (`value`) moves down to become the right child of `cursor`.
     *
     * The function updates the relevant parent and child pointers to maintain the correct tree structure.
     *
     * The function follows these steps:
     *
     * 1. Assigns the left child of `value` to `cursor`, and stores the node in `nodeCursor`.
     * 2. Moves the right child of `cursor` to become the left child of `value`.
     * 3. Updates the parent of `cursor` to be the parent of `value`, and adjusts the parent's child pointer.
     * 4. Sets `value` as the right child of `cursor`, completing the rotation.
     * 5. Updates the `count` properties of both `cursor` and `value` to reflect the new subtree sizes.
     *
     * @param self A reference to the `Tree` struct in storage, containing the nodes and root of the Red-Black tree.
     * @param value The value of the node to rotate right.
     */
    function rotateRight(Tree storage self, uint256 value) private {
        Node storage nodeValue = self.nodes[value];
        uint256 cursor = nodeValue.left;
        Node storage nodeCursor = self.nodes[cursor];

        uint256 cursorRight = nodeCursor.right;
        nodeValue.left = cursorRight;

        if (cursorRight != EMPTY) {
            self.nodes[cursorRight].parent = value;
        }

        uint256 parent = nodeValue.parent;
        nodeCursor.parent = parent;

        if (parent == EMPTY) {
            self.root = cursor;
        } else if (value == self.nodes[parent].right) {
            self.nodes[parent].right = cursor;
        } else {
            self.nodes[parent].left = cursor;
        }

        nodeCursor.right = value;
        nodeValue.parent = cursor;
    }

    /**
     * @dev Corrects the properties of the Red-Black Tree after an insertion.
     *
     * This function ensures the tree adheres to Red-Black properties:
     * 1. No two consecutive red nodes.
     * 2. Every path from a node to its descendant leaves has the same number of black nodes.
     * 3. The root is always black.
     *
     * The function operates as follows:
     * 1. It checks if the newly inserted node's parent is red and if the node is not the root.
     * 2. If the parent is a left child of its parent (grandparent), it handles two cases:
     *    - Case 1: The grandparent's right child (uncle) is red. It recolors the parent, uncle, and grandparent, and then moves up to the grandparent.
     *    - Case 2: The uncle is black. If the newly inserted node is a right child, it performs a left rotation on the parent node. Then, it recolors and performs a right rotation on the grandparent.
     * 3. If the parent is a right child of the grandparent, it similarly handles two cases:
     *    - Case 1: The grandparent's left child (uncle) is red. It recolors the parent, uncle, and grandparent, and then moves up to the grandparent.
     *    - Case 2: The uncle is black. If the newly inserted node is a left child, it performs a right rotation on the parent node. Then, it recolors and performs a left rotation on the grandparent.
     * 4. Finally, it ensures the root of the tree is black.
     *
     * @param self A reference to the `Tree` struct in storage, representing the Red-Black tree.
     * @param value The value of the node that was recently inserted and may need fixing.
     */
    function insertFixup(Tree storage self, uint256 value) private {
        uint256 parent;
        uint256 grandParent;
        uint256 uncle;

        while (value != self.root && self.nodes[self.nodes[value].parent].red) {
            parent = self.nodes[value].parent;
            grandParent = self.nodes[parent].parent;

            if (parent == self.nodes[grandParent].left) {
                uncle = self.nodes[grandParent].right;
                if (self.nodes[uncle].red) {
                    // Case 1: Uncle is red
                    self.nodes[parent].red = false;
                    self.nodes[uncle].red = false;
                    self.nodes[grandParent].red = true;
                    value = grandParent; // Move up the tree
                } else {
                    // Case 2: Uncle is black
                    if (value == self.nodes[parent].right) {
                        // Perform left rotation on parent
                        value = parent;
                        rotateLeft(self, value);
                    }
                    parent = self.nodes[value].parent;
                    // Perform right rotation on grandParent
                    self.nodes[parent].red = false;
                    self.nodes[grandParent].red = true;
                    rotateRight(self, grandParent);
                }
            } else {
                // Symmetric case when parent is right child of grandParent
                uncle = self.nodes[grandParent].left;
                if (self.nodes[uncle].red) {
                    // Case 1: Uncle is red
                    self.nodes[parent].red = false;
                    self.nodes[uncle].red = false;
                    self.nodes[grandParent].red = true;
                    value = grandParent; // Move up the tree
                } else {
                    // Case 2: Uncle is black
                    if (value == self.nodes[parent].left) {
                        // Perform right rotation on parent
                        value = parent;
                        rotateRight(self, value);
                    }
                    parent = self.nodes[value].parent;
                    // Perform left rotation on grandParent
                    self.nodes[parent].red = false;
                    self.nodes[grandParent].red = true;
                    rotateLeft(self, grandParent);
                }
            }
        }
        // Ensure the root is black
        self.nodes[self.root].red = false;
    }

    /**
     * @dev Replaces the parent reference of a node `b` with node `a`.
     *
     * This function updates the parent reference of node `a` to match the parent of node `b`,
     * and adjusts the parent's link to point to node `a` instead of node `b`.
     *
     * - If node `b` is the root of the tree, node `a` becomes the new root.
     * - Otherwise, node `a` replaces node `b` as a child of node `b`'s parent.
     *
     * @param self A reference to the `Tree` struct in storage, representing the tree.
     * @param a The node that will replace node `b`.
     * @param b The node that will be replaced by node `a`.
     */
    function replaceParent(Tree storage self, uint256 a, uint256 b) private {
        // Cache parent of node b
        uint256 bParent = self.nodes[b].parent;
        Node storage nodeA = self.nodes[a]; // Cache node a
        // Set the parent of node a
        nodeA.parent = bParent;

        if (bParent == EMPTY) {
            // Node b is the root, so node a becomes the new root
            self.root = a;
        } else {
            // Update the link of bParent to point to node a
            if (b == self.nodes[bParent].left) {
                self.nodes[bParent].left = a;
            } else {
                self.nodes[bParent].right = a;
            }
        }
    }

    /**
     * @dev Restores Red-Black tree properties after the removal of a node.
     *
     * This function ensures that the Red-Black tree maintains its properties after
     * removing a node. It corrects the tree by performing color adjustments and rotations.
     *
     * The function:
     * 1. Iterates up the tree from the node that was removed, adjusting colors and performing rotations
     *    as necessary to maintain Red-Black tree properties.
     * 2. Ensures that the root of the tree remains black and all properties of Red-Black trees are preserved.
     *
     * @param self The `Tree` storage reference containing the tree nodes and root.
     * @param value The value of the node that needs correction after removal.
     */
    function removeFixup(Tree storage self, uint256 value) private {
        uint256 cursor;
        while (value != self.root && !self.nodes[value].red) {
            uint256 valueParent = self.nodes[value].parent;
            bool isLeftChild = value == self.nodes[valueParent].left;
            cursor = isLeftChild ? self.nodes[valueParent].right : self.nodes[valueParent].left;

            // Case 1: Brother node is red
            if (self.nodes[cursor].red) {
                self.nodes[cursor].red = false;
                self.nodes[valueParent].red = true;
                if (isLeftChild) {
                    rotateLeft(self, valueParent);
                    cursor = self.nodes[valueParent].right;
                } else {
                    rotateRight(self, valueParent);
                    cursor = self.nodes[valueParent].left;
                }
            }

            // Case 2: Both children of the brother are black
            bool leftChildBlack = !self.nodes[self.nodes[cursor].left].red;
            bool rightChildBlack = !self.nodes[self.nodes[cursor].right].red;

            if (leftChildBlack && rightChildBlack) {
                self.nodes[cursor].red = true;
                value = valueParent;
            } else {
                // Case 3: Brother's right child is black
                if (isLeftChild && rightChildBlack) {
                    self.nodes[self.nodes[cursor].left].red = false;
                    self.nodes[cursor].red = true;
                    rotateRight(self, cursor);
                    cursor = self.nodes[valueParent].right;
                } else if (!isLeftChild && leftChildBlack) {
                    self.nodes[self.nodes[cursor].right].red = false;
                    self.nodes[cursor].red = true;
                    rotateLeft(self, cursor);
                    cursor = self.nodes[valueParent].left;
                }

                // Case 4: Adjust colors and perform rotation
                self.nodes[cursor].red = self.nodes[valueParent].red;
                self.nodes[valueParent].red = false;
                if (isLeftChild) {
                    self.nodes[self.nodes[cursor].right].red = false;
                    rotateLeft(self, valueParent);
                } else {
                    self.nodes[self.nodes[cursor].left].red = false;
                    rotateRight(self, valueParent);
                }
                value = self.root;
            }
        }
        self.nodes[value].red = false;
    }
}
