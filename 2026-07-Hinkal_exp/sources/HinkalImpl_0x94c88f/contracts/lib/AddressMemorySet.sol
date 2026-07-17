// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

// Note: purpose of this datastrucutre is to be stored in memory
// consider using EnumerableSet from openzeppelin if you would like a storage set
library AddressMemorySet {
    struct Set {
        address[] inner;
        uint256 length;
        uint256 maxLength;
    }

    function init(uint256 maxLength) internal pure returns (Set memory result) {
        result = Set(new address[](maxLength), 0, maxLength);
    }

    function has(Set memory set, address value) internal pure returns (bool) {
        uint256 length = set.length;
        for (uint256 i = 0; i < length; i++)
            if (set.inner[i] == value) return true;

        return false;
    }

    function insert(Set memory set, address value) internal pure {
        if (has(set, value)) return;
        set.inner[set.length++] = value;
        require(set.length <= set.maxLength, "Set MaxLength Reached");
    }
}
