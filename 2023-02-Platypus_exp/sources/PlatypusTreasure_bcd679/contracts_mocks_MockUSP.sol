// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import '../lending/USP.sol';

contract MockUSP is USP {
    function faucet(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
