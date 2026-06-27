// contracts/VOWToken.sol
// SPDX-License-Identifier: None
pragma solidity 0.8.18;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract VOWToken is ERC20Burnable, AccessControl {

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    event Bridge(address indexed src, uint256 amount, uint256 chainId);

    constructor() ERC20("Vow", "VOW") {
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function mint(
        address account, 
        uint256 amount
    ) public onlyRole(MINTER_ROLE) returns (bool) {
        _mint(account, amount);
        return true;
    }

    function bridge(uint256 amount, uint256 chainId) public {
        _burn(_msgSender(), amount);
        emit Bridge(_msgSender(), amount, chainId);
    }
}