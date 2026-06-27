// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "../Liquidator.sol";

contract LiquidatorMock is Liquidator {
    constructor(address provider, address swapRouter) public Liquidator(provider, swapRouter) { }
}
