// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract MinterControl is AccessControl {
    bytes32 public constant SMOLBRAIN_OWNER_ROLE = keccak256("SMOLBRAIN_OWNER_ROLE");
    bytes32 public constant SMOLBRAIN_MINTER_ROLE = keccak256("SMOLBRAIN_MINTER_ROLE");

    modifier onlyOwner() {
        require(hasRole(SMOLBRAIN_OWNER_ROLE, _msgSender()), "MinterControl: not a SMOLBRAIN_OWNER_ROLE");
        _;
    }

    modifier onlyMinter() {
        require(isMinter(_msgSender()), "MinterControl: not a SMOLBRAIN_MINTER_ROLE");
        _;
    }

    constructor() {
        _setRoleAdmin(SMOLBRAIN_OWNER_ROLE, SMOLBRAIN_OWNER_ROLE);
        _setRoleAdmin(SMOLBRAIN_MINTER_ROLE, SMOLBRAIN_OWNER_ROLE);

        _setupRole(SMOLBRAIN_OWNER_ROLE, _msgSender());
    }

    function grantMinter(address _minter) external {
        grantRole(SMOLBRAIN_MINTER_ROLE, _minter);
    }

    function isMinter(address _minter) public view returns (bool) {
        return hasRole(SMOLBRAIN_MINTER_ROLE, _minter);
    }

    function grantOwner(address _owner) external {
        grantRole(SMOLBRAIN_OWNER_ROLE, _owner);
    }

    function isOwner(address _owner) public view returns (bool) {
        return hasRole(SMOLBRAIN_OWNER_ROLE, _owner);
    }
}
