// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title LUSD
 * @author LAYER3-TEAM
 * @notice Contract to supply LUSD
 */
contract LUSD is ERC20, AccessControlEnumerable {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /**
     * @param manager Initialize Manager Role
     */
    constructor(address manager) ERC20("LUSD", "Layer3 USD") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MANAGER_ROLE, manager);
    }

    /**
     * @dev Mint
     */
    function mint(
        address user,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) {
        _mint(user, amount);
    }

    /**
     * @dev Burn
     */
    function burn(
        address user,
        uint256 amount
    ) external onlyRole(MANAGER_ROLE) {
        _burn(user, amount);
    }
}
