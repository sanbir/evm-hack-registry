// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IProject {
    function dividendWallet() external view returns (address);
    function marketingAddress() external view returns (address);
    function ecosystemAddress() external view returns (address);
}