//SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

interface IBP {
    function beforeTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (uint256, uint256);
}
