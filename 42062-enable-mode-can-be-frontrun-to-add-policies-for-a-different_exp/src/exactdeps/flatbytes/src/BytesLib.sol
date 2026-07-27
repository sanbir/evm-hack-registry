// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title FlatBytesLib
 * @dev Library for storing bytes data in consecutive storage slots
 * @dev This is useful in the context of the ERC-4337 validation rules
 * @dev Be careful that this does not override existing data in the next slots and ideally use this
 * data as the value of a struct
 * @author Rhinestone
 */
library FlatBytesLib {
    using FlatBytesLib for *;

    /*//////////////////////////////////////////////////////////////////////////
                                    DATA STRUCTURES
    //////////////////////////////////////////////////////////////////////////*/

    // Data structure to store bytes in consecutive slots using an array
    struct Data {
        bytes32[10] slot1;
    }

    // Store the length of the data and the data itself in consecutive slots
    struct Bytes {
        uint256 totalLength;
        Data data;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Store the data in storage
     *
     * @param self The storage to store the data in
     * @param data The data to store
     */
    function store(Bytes storage self, bytes memory data) internal {
        if (data.length > 32 * 10) revert();
        bytes32[] memory entries;
        (self.totalLength, entries) = data.toArray();

        uint256 length = entries.length;

        Data storage _data = self.data;

        for (uint256 i; i < length; i++) {
            bytes32 value = entries[i];
            assembly {
                sstore(add(_data.slot, i), value)
            }
        }
    }

    /**
     * Clear the data in storage
     *
     * @param self The storage to clear the data in
     */
    function clear(Bytes storage self) internal {
        self.totalLength = 0;
        Data storage _data = self.data;
        for (uint256 i; i < 10; i++) {
            assembly {
                sstore(add(_data.slot, i), 0)
            }
        }
    }

    /**
     * Load the data from storage
     *
     * @param self The storage to load the data from
     *
     * @return data The data loaded from storage
     */
    function load(Bytes storage self) internal view returns (bytes memory data) {
        return self.toBytes();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Convert bytes to an array of bytes32
     *
     * @param data The data to convert
     * @return totalLength The total length of the data
     *
     * @return dataList The data as an array of bytes32
     */
    function toArray(bytes memory data)
        internal
        pure
        returns (uint256 totalLength, bytes32[] memory dataList)
    {
        // Find 32 bytes segments nb
        totalLength = data.length;
        if (totalLength > 32 * 10) revert();
        uint256 dataNb = totalLength / 32 + 1;

        // Create an array of dataNb elements
        dataList = new bytes32[](dataNb);

        // Loop all 32 bytes segments
        for (uint256 i = 0; i < dataNb; i++) {
            bytes32 temp;
            // Get 32 bytes from data
            assembly {
                temp := mload(add(data, mul(add(i, 1), 32)))
            }
            // Add extracted 32 bytes to list
            dataList[i] = temp;
        }
    }

    /**
     * Convert an array of bytes32 to bytes
     *
     * @param self The array of bytes32 to convert
     *
     * @return data The data as bytes
     */
    function toBytes(Bytes storage self) internal view returns (bytes memory data) {
        uint256 totalLength = self.totalLength;
        uint256 slotsCnt = totalLength / 32 + 1;

        Data storage _data = self.data;

        bytes32[] memory entries = new bytes32[](slotsCnt);
        for (uint256 i; i < slotsCnt; i++) {
            bytes32 tmp;
            assembly {
                tmp := sload(add(_data.slot, i))
            }
            entries[i] = tmp;
        }

        data = abi.encodePacked(entries);
        assembly {
            mstore(data, totalLength)
        }
    }
}
