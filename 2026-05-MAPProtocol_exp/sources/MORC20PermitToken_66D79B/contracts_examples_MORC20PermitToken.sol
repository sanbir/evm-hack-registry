// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "../morc20/MORC20Token.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MORC20PermitToken is MORC20Token, ERC20Permit {
    constructor(
        string memory _name,
        string memory _symbol,
        address _mosAddress,
        uint256 _initialSupply,
        address _owner
    ) MORC20Token(_name, _symbol, _mosAddress) ERC20Permit(_name) {
        _transferOwnership(_owner);
        _mint(_owner, _initialSupply);
    }
}
