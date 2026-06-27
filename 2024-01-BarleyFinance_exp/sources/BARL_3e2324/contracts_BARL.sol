// Website: https://barley.finance
// Docs:  https://docs.barley.finance
// Twitter: https://twitter.com/Barley_Finance
// Telegram Group: https://t.me/Barley_Finance
// Telegram Channel: https://t.me/BarleyFinance

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IBARL.sol";

contract BARL is IBARL, ERC20 {
    constructor() ERC20("Barley Finance", "BARL") {
        _mint(_msgSender(), 100_000_000 * 10 ** 18);
    }

    function burn(uint256 _amount) external override {
        _burn(_msgSender(), _amount);
        emit Burn(_msgSender(), _amount);
    }
}
