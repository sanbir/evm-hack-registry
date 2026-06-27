// SPDX-License-Identifier: MIT
pragma solidity ^0.5.17;

interface Api3ProxyInterface {
    function read() external view returns (int224 value, uint32 timestamp);
}
