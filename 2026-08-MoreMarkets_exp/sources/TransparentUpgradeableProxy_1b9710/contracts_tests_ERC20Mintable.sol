// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

contract ERC20Mintable is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) payable ERC20(name_, symbol_) {}

    function mint(address usr, uint wad) external {
        _mint(usr, wad);
    }

    function burn(address usr, uint wad) external {
        _burn(usr, wad);
    }
}
