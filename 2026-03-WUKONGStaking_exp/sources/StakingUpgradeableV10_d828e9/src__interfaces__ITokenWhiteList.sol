// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenWhiteList {
    function WHITE_LIST(address account) external view returns (bool);
}