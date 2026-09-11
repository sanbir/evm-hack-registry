// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ERC20Mock is ERC20, Ownable {
  constructor() ERC20("ERC20Mock", "M") Ownable(msg.sender) {}

  function mint(address account, uint256 value) public onlyOwner {
    _mint(account, value);
  }

  function burn(address account, uint256 value) public onlyOwner {
    _burn(account, value);
  }
}
