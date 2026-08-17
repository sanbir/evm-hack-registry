// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract StakedFox is ERC20, Ownable {
 
    address public treasury;
  
    constructor(string memory _name, string memory _symbol, uint256 _mintAmount) ERC20(_name, _symbol) Ownable(msg.sender) {
        if(_mintAmount > 0){
            _mint(msg.sender, _mintAmount * (10**decimals()));
        }
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        treasury = _newTreasury;
    }
   
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == treasury, "Unauthorized");

        _mint(_to, _amount);
    }

}