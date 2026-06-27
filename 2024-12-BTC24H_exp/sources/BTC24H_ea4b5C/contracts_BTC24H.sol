// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import { ERC20Burnable } from '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol';

contract BTC24H is ERC20, ERC20Burnable {
    constructor() ERC20('BTC24H', 'BTC24H') {
        _mint(msg.sender, 21000000 * 10 ** decimals());
    }
}
