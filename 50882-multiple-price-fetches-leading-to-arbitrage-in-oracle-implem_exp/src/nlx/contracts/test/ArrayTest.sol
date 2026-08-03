
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../utils/Array.sol";

/**
 * @title ArrayTest
 * @dev Contract to help test the Array library
 */
contract ArrayTest {
    function getMedian(uint256[] memory arr) external pure returns (uint256) {
        return Array.getMedian(arr);
    }
}
