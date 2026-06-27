
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract SwapERC20 is ERC20, ERC20Burnable, ERC20Permit {
    constructor() ERC20("BigBangSwap LP Token", "BBG-LP") ERC20Permit("BigBangSwap LP Token") {
    }
}
