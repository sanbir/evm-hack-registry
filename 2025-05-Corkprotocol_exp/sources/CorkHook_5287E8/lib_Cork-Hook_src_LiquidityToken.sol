pragma solidity 0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract LiquidityToken is ERC20Upgradeable, ERC20PermitUpgradeable, ERC20BurnableUpgradeable, OwnableUpgradeable {
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory name, string memory symbol, address owner) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC20Burnable_init();
        __Ownable_init(owner);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) public override onlyOwner {
        super.burn(amount);
    }
}
