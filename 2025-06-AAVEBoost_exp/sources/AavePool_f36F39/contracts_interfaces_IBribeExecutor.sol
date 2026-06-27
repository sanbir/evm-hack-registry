// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IBribeExecutor {
    function execute(
        address user,
        uint256 amount,
        bytes calldata data
    ) external;
}
