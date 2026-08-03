// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILpdFi { 
    function fiStartTime() external view returns (uint256);
    function ISSUE_PERIOD() external view returns (uint64);
}
