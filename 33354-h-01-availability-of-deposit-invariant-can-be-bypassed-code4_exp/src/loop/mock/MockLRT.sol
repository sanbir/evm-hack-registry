// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Verbatim from code-423n4/2024-05-loop src/mock/MockLRT.sol
// A plain wrapped-LRT ERC20 (the "allowed token" the protocol treats as opaque).
contract LRToken is ERC20 {
    constructor() ERC20("LRT", "LRT") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
