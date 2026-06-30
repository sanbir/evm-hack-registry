// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IMarket {
    function buyFor(address account, uint256 minTokens, address recipient, uint160 sqrtPriceLimitX96)
        external
        payable;
}
