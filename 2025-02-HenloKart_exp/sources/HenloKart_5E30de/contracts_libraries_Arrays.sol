/// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library Arrays {
    function from(uint256 item) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = item;
    }

    function contains(address[] storage list, address item) internal view returns (bool) {
        for (uint256 i = 0; i < list.length;) {
            if (list[i] == item) {
                return true;
            }

            unchecked { i++; }
        }

        return false;
    }

    function add(uint256[] memory list, uint256 item) internal pure returns (uint256[] memory newList) {
        newList = new uint256[](list.length + 1);
        for (uint256 i = 0; i < list.length;) {
            newList[i] = list[i];

            unchecked {
                i++;
            }
        }
        newList[list.length] = item;
    }

    function sort(uint256[] memory list) internal pure returns (uint256[] memory) {
        for (uint256 i = 0; i < list.length;) {
            bool swapped;
            
            for (uint256 j = 0; j < list.length - i - 1;) {
                if (list[j] < list[j + 1]) {
                    (list[j], list[j + 1]) = (list[j + 1], list[j]);
                    swapped = true;
                }

                unchecked {
                    j++;
                }
            }
            
            if (!swapped) {
                break;
            }

            unchecked {
                i++;
            }
        }

        return list;
    }

    function sortIndexes(uint256[] memory list) internal pure returns (uint256[] memory indexes) {
        indexes = new uint256[](list.length);
        for (uint256 i = 0; i < list.length;) {
            indexes[i] = i;
            unchecked { i++; }
        }

        for (uint256 i = 0; i < list.length;) {
            bool swapped;
            
            for (uint256 j = 0; j < list.length - i - 1;) {
                if (list[indexes[j]] < list[indexes[j + 1]]) {
                    (indexes[j], indexes[j + 1]) = (indexes[j + 1], indexes[j]);
                    swapped = true;
                }

                unchecked {
                    j++;
                }
            }
            
            if (!swapped) {
                break;
            }

            unchecked {
                i++;
            }
        }
    }
}