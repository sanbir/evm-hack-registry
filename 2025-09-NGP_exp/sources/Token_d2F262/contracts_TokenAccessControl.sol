// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract TokenAccessControl is AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
    }

    // Modifier for admin roles
    modifier onlyOwner() {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Not an admin role");
        _;
    }

    // Modifier for minting roles
    modifier onlyMinter() {
        require(hasRole(MINTER_ROLE, _msgSender()), "Not a minter role");
        _;
    }
}
