// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {ERC6909} from "solmate/tokens/ERC6909.sol";

abstract contract ERC6909Supply is ERC6909 {
    mapping(uint256 => uint256) public totalSupply;

    function _mint(address receiver, uint256 id, uint256 amount) internal virtual override {
        super._mint(receiver, id, amount);
        totalSupply[id] += amount;
    }

    function _burn(address sender, uint256 id, uint256 amount) internal virtual override {
        super._burn(sender, id, amount);
        totalSupply[id] -= amount;
    }
}
