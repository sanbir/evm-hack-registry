// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

interface ITokenLending {
    function exchangeRateCurrent() external returns (uint);
    function mint(uint mintAmount) external returns (uint);
    function redeem(uint) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
}