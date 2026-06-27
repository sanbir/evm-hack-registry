// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "contracts/interfaces/IMintable.sol";
import "contracts/interfaces/IBurnable.sol";

import "hardhat/console.sol";

/**
 * This is forked from Sushiswap, hence the name "SushiBar". Masterchef owns it
 */

// SushiBar is the coolest bar in town. You come in with some Sushi, and leave with more! The longer you stay, the more Sushi you get.
//
// This contract handles swapping to and from xSushi, SushiSwap's staking token.
contract RewardBar is ERC20, IMintable, Ownable {
    IERC20 immutable public lev;

    // Define the Sushi token contract
    constructor(IERC20 _lev) ERC20("Staked LEV", "SLEV") {
        lev = _lev;
    }

    function mint(address receiver, uint256 amount) override external onlyOwner {
        _mint(receiver, amount);
    }

    function burn(address account, uint256 amount) external onlyOwner {
        _burn(account, amount);
    }

    // Safe cake transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function safeCakeTransfer(address _to, uint256 _amount) public onlyOwner {
        safeTokenTransfer(_to, _amount, lev);
    }

    // Safe busd transfer function, just in case if rounding error causes pool to not have enough CAKEs.
    function safeTokenTransfer(address _to, uint256 _amount, IERC20 _token) public onlyOwner {
        uint256 bal = _token.balanceOf(address(this));
        if (_amount > bal) {
            require(_token.transfer(_to, bal), "Sushibar: TRANSFER_FAILED");
        } else {
            require(_token.transfer(_to, _amount), "SushiBar: TRANSFER_FAILED");
        }
    }
}
