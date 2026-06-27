// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IEscrow {
    function vestingLock(
        address owner,
        uint256 amount
    ) external returns (uint256 id);
}
