// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library QueueLib {
    /* Errors */
    error QL__EmptyQueue();
    error QL__ItemAlreadyExists();
    error QL__ItemDoesNotExist();

    /**
     *  @notice Structure of an order within the node.
     */
    struct Item {
        /// @notice Unique identifier for the item
        bytes32 id;
        /// @notice ID of the next item in the queue (0 if last)
        bytes32 next;
        /// @notice ID of the previous item in the queue (0 if first)
        bytes32 prev;
    }

    /**
     * @notice Structure of the queue itself.
     */
    struct Queue {
        /// @notice ID of the first item in the queue (0 if empty)
        bytes32 first;
        /// @notice ID of the last item in the queue (0 if empty)
        bytes32 last;
        /// @notice Mapping from item ID to Item struct
        mapping(bytes32 => Item) items;
    }

    /* View Functions */

    /**
     * @notice Check if an item exists in the queue.
     * @param q The queue to check.
     * @param _itemId The ID of the item to check.
     * @return bool True if the item exists, false otherwise.
     */
    function itemExists(Queue storage q, bytes32 _itemId) internal view returns (bool) {
        if (_itemId == 0) return false;
        return q.items[_itemId].id != 0;
    }

    /**
     * @notice Check if the queue is empty.
     * @param q The queue to check.
     * @return bool True if the queue is empty, false otherwise.
     */
    function isEmpty(Queue storage q) internal view returns (bool) {
        return q.first == 0;
    }

    /* Mutative Functions */

    /**
     * @notice Push a new item to the end of the queue.
     * @param q The queue to push to.
     * @param _itemId The ID of the item to push.
     */
    function push(Queue storage q, bytes32 _itemId) internal {
        // Check if the item is valid and doesn't already exist
        if (_itemId == 0 || itemExists(q, _itemId)) revert QL__ItemAlreadyExists();

        // If the queue is not empty, update the 'next' pointer of the current last item
        if (q.last != 0) {
            q.items[q.last].next = _itemId;
        } else {
            // If the queue was empty, set the new item as the first item
            q.first = _itemId;
        }

        // Create the new item and add it to the queue
        q.items[_itemId] = Item({id: _itemId, prev: q.last, next: 0});
        // Create the new item and add it to the queue
        q.last = _itemId;
    }

    /**
     * @notice Remove an item from the queue.
     * @param q The queue to remove from.
     * @param _itemId The ID of the item to remove.
     */
    function remove(Queue storage q, bytes32 _itemId) internal {
        // Check if the queue is empty or if the item doesn't exist
        if (_itemId == 0 || isEmpty(q)) revert QL__EmptyQueue();
        if (!itemExists(q, _itemId)) revert QL__ItemDoesNotExist();

        // Store the item to be removed in memory
        Item memory removedItem = q.items[_itemId];
        // Remove the item from the mapping
        delete q.items[_itemId];

        // Update the first pointer if we're removing the first item
        if (q.first == _itemId) {
            q.first = removedItem.next;
        }
        // Update the last pointer if we're removing the last item
        if (q.last == _itemId) {
            q.last = removedItem.prev;
        }
        // Update the 'prev' pointer of the next item
        if (removedItem.next != 0) {
            q.items[removedItem.next].prev = removedItem.prev;
        }
        // Update the 'next' pointer of the previous item
        if (removedItem.prev != 0) {
            q.items[removedItem.prev].next = removedItem.next;
        }
    }
}
