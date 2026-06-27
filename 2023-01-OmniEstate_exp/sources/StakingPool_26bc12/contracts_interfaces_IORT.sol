// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.0;

import "./IBEP20.sol";
import "./crosschain/IAnyswapV4ERC20.sol";

interface IORT is IBEP20, IAnyswapV4ERC20 {
    function mint(uint256 amount) external returns (bool);
    function burn(uint256 amount) external returns (bool);
}