// SPDX-License-Identifier: Unlicensed

pragma solidity ^0.8.0;
pragma abicoder v2;

interface ISmoofs {
    function mint(address to) external;

    function batchMint(address to, uint256 amount) external;
}
