// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

interface IRateModel {
    function rate(uint256) external view returns (uint256);
}
