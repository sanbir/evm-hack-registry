// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MintableERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract OwnedMintableERC20 is ERC20 {
    address public owner;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        owner = msg.sender;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == owner, "Not Owner");
        _mint(account, amount);
    }
}
