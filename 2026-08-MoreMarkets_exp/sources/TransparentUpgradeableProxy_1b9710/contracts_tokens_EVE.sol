// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract Eventum is ERC20, ERC20Burnable {
    constructor() ERC20("Eventum", "EVE") {
        _mint(msg.sender, 100000000 * 10 ** decimals());
    }
}
