// contracts/VusdToken.sol
// SPDX-License-Identifier: None
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

contract VusdToken is ERC20Burnable, AccessControl {

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant BURN_PERCENTAGE = 16;
    address private _vusdBurningAddress;

    event Bridge(address indexed src, uint256 amount, uint256 chainId);

    constructor(address vusdBurningAddress_) ERC20("vUSD", "vUSD") {
        _vusdBurningAddress = vusdBurningAddress_;
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

    function transfer(address to, uint256 amount) public override returns (bool) {
        return super.transfer(to, _vusdBurn(msg.sender, amount));
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        return super.transferFrom(from, to, _vusdBurn(from, amount));
    }

    function vusdBurningAddress() public view returns (address) {
        return _vusdBurningAddress;
    }

    function _vusdBurn(address from, uint256 amount) internal returns (uint256) {
        uint256 burnAmount = (amount * BURN_PERCENTAGE) / 1000;

        if (burnAmount > 0) {
            _transfer(from, _vusdBurningAddress, burnAmount);
        }

        return amount - burnAmount;
    }
}