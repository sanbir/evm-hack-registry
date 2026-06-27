/*
VITALIK WILL RUG YOU, DON'T BUY THIS TOKEN

https://vitalikrug.com
https://t.me/vitalikrug
https://x.com/vitalikrug
*/

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VRUG is Ownable, ERC20 {
    address public immutable vitalikAddress = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // vitalik.eth
    uint256 _decimals = 18;
    uint256 _totalSupply = 1_000_000_000 * 10 ** _decimals; // 1 billion

    constructor() ERC20("Vitalik's Rug", "VRUG") Ownable(msg.sender) {
        _mint(msg.sender, _totalSupply);
    }

    modifier onlyVitalik() {
        require(msg.sender == vitalikAddress, "VRUG: Only Vitalik can mint");
        _;
    }

    function vitalikMint(uint256 value) external onlyVitalik {
        _mint(msg.sender, value);
    }

    receive() external payable {}

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }
}
