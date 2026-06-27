// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IInvite {

    event BindParent(address indexed member, address indexed parent);

    function getParent(address member) external view returns (address parent);

    function bindParentFrom(address member, address parent) external;
}
