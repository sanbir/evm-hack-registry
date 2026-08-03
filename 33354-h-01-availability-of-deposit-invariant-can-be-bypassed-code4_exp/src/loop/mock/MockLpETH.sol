// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "../interfaces/ILpETH.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Verbatim from code-423n4/2024-05-loop src/mock/MockLpETH.sol
// (only the import path is adjusted to the vendored interface location).
contract MockLpETH is ILpETH, ERC20 {
    constructor() ERC20("LoopETH", "lpETH") {}

    function deposit(address receiver) external payable returns (uint256) {
        super._mint(receiver, msg.value);
        return msg.value;
    }
}
