pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract EphemeralERC20Type1 is ERC20, AccessControl {
    uint8 private immutable _decimals;

    bytes32 public constant FACADE_ROLE = keccak256("FACADE_ROLE");

    constructor(
        string memory name,
        string memory symbol,
        uint8 __decimals
    ) ERC20(name, symbol) {
        _decimals = __decimals;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mintTo(address account, uint256 amount) external onlyRole(FACADE_ROLE) {
        _mint(account, amount);
    }

    function burnTo(address account, uint256 amount) external onlyRole(FACADE_ROLE) {
        _burn(account, amount);
    }

}
