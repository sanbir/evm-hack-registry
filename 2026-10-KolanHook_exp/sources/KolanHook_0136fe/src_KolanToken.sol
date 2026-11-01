// SPDX-License-Identifier: BUSL-1.1
/*
 *        ▄▄▄▄▄▄▄▄▄▄
 *     ▄▄████████████▄▄
 *    ▄████████████████▄
 *   ████████████████████
 *  ████████▀    ▀████████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████        ███████
 *  ███████  ▄██▄  ███████
 *  ███████ ██████ ███████
 *  ███████  ▀██▀  ███████
 *
 *  Kolan
 *
 *  Website   https://kolan.c0llback.com
 *  Twitter   https://x.com/kolan_protocol
 */
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract KolanToken is ERC20Burnable {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) {
        _mint(msg.sender, supply);
    }
}
