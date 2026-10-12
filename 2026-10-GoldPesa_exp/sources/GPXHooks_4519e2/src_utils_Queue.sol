// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title Queue
 * @author Erick Dagenais (https://github.com/edag94)
 * @dev Implementation of the queue data structure, providing a library with struct definition for queue storage in consuming contracts.
 */
library Queue {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Queue type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.
    // Based off the pattern used in https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/structs/EnumerableSet.sol[EnumerableSet.sol] by OpenZeppelin

    struct QueueStorage {
        mapping (uint256 => bytes32) _data;
        uint256 _first;
        uint256 _last;
    }

    modifier isNotEmpty(QueueStorage storage queue) {
        require(!_isEmpty(queue), "Queue is empty.");
        _;
    }

    /**
     * @dev Sets the queue's initial state, with a queue size of 0.
     * @param queue QueueStorage struct from contract.
     */
    function _initialize(QueueStorage storage queue) private {
        queue._first = 1;
        queue._last = 0;
    }

    /**
     * @dev Gets the number of elements in the queue. O(1)
     * @param queue QueueStorage struct from contract.
     */
    function _length(QueueStorage storage queue) private view returns (uint256) {
        if (queue._last < queue._first) {
            return 0;
        }
        return queue._last - queue._first + 1;
    }

    /**
     * @dev Returns if queue is empty. O(1)
     * @param queue QueueStorage struct from contract.
     */
    function _isEmpty(QueueStorage storage queue) private view returns (bool) {
        return _length(queue) == 0;
    }

    /**
     * @dev Adds an element to the back of the queue. O(1)
     * @param queue QueueStorage struct from contract.
     * @param data The added element's data.
     */
    function _enqueue(QueueStorage storage queue, bytes32 data) private {
        queue._data[++queue._last] = data;
    }

    /**
     * @dev Removes an element from the front of the queue and returns it. O(1)
     * @param queue QueueStorage struct from contract.
     */
    function _dequeue(QueueStorage storage queue) private isNotEmpty(queue) returns (bytes32 data) {
        data = queue._data[queue._first];
        delete queue._data[queue._first++];
    }

    /**
     * @dev Returns the data from the front of the queue, without removing it. O(1)
     * @param queue QueueStorage struct from contract.
     */
    function _peek(QueueStorage storage queue) private view isNotEmpty(queue) returns (bytes32 data) {
        return queue._data[queue._first];
    }

    /**
     * @dev Returns the data from the back of the queue. O(1)
     * @param queue QueueStorage struct from contract.
     */
    function _peekLast(QueueStorage storage queue) private view isNotEmpty(queue) returns (bytes32 data) {
        return queue._data[queue._last];
    }

    /* REMOVED BYTES32QUEUE AND ADDRESSQUEUE AS THEY WERE NOT NEEDED */
    
    // Uint256Queue
    struct Uint256Queue {
        QueueStorage _inner;
    }

    /**
     * @dev Sets the queue's initial state, with a queue size of 0.
     * @param queue Uint256Queue struct from contract.
     */
    function initialize(Uint256Queue storage queue) internal {
        _initialize(queue._inner);
    }

    /**
     * @dev Gets the number of elements in the queue. O(1)
     * @param queue Uint256Queue struct from contract.
     */
    function length(Uint256Queue storage queue) internal view returns (uint256) {
        return _length(queue._inner);
    }

    /**
     * @dev Returns if queue is empty. O(1)
     * @param queue Uint256Queue struct from contract.
     */
    function isEmpty(Uint256Queue storage queue) internal view returns (bool) {
        return _isEmpty(queue._inner);
    }

    /**
     * @dev Adds an element to the back of the queue. O(1)
     * @param queue Uint256Queue struct from contract.
     * @param data The added element's data.
     */
    function enqueue(Uint256Queue storage queue, uint256 data) internal {
        _enqueue(queue._inner, bytes32(data));
    }

    /**
     * @dev Removes an element from the front of the queue and returns it. O(1)
     * @param queue Uint256Queue struct from contract.
     */
    function dequeue(Uint256Queue storage queue) internal returns (uint256 data) {
        return uint256(_dequeue(queue._inner));
    }

    /**
     * @dev Returns the data from the front of the queue, without removing it. O(1)
     * @param queue Uint256Queue struct from contract.
     */
    function peek(Uint256Queue storage queue) internal view returns (uint256 data) {
        return uint256(_peek(queue._inner));
    }

    /**
     * @dev Returns the data from the back of the queue. O(1)
     * @param queue Uint256Queue struct from contract.
     */
    function peekLast(Uint256Queue storage queue) internal view returns (uint256 data) {
        return uint256(_peekLast(queue._inner));
    }
}