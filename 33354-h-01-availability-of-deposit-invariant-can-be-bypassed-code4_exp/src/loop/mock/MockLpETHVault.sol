// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "../interfaces/ILpETHVault.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Verbatim from code-423n4/2024-05-loop src/mock/MockLpETHVault.sol
// (only the import path is adjusted to the vendored interface location).
contract MockLpETHVault is ILpETHVault, ERC20 {
    constructor() ERC20("Staked LoopETH", "stlpETH") {}

    function stake(uint256 amount, address receiver) external returns (uint256) {
        _mint(receiver, amount);
        return amount;
    }
}
