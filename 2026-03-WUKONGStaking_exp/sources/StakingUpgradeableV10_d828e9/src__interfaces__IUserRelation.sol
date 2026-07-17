// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUserRelation {
    function getParent(address user_) external view returns(address);
    function topAddress() external view returns(address);
}