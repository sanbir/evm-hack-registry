// SPDX-License-Identifier:  MIT
pragma solidity 0.8.10;

interface ILFIToken {
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
}