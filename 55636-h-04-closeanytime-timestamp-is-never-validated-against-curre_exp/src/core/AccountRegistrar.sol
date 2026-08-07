// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.4;

import "../interfaces/Interfaces.sol";
import "./Validator.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @author Heisenberg
 * @notice Buffer Options Router Contract
 */
contract AccountRegistrar is IAccountRegistrar, AccessControl {
    mapping(address => AccountMapping) public override accountMapping;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function registerAccount(
        address oneCT,
        address user,
        bytes memory signature
    ) external override onlyRole(ADMIN_ROLE) {
        if (accountMapping[user].oneCT == oneCT) {
            return;
        }
        uint256 nonce = accountMapping[user].nonce;
        require(
            Validator.verifyUserRegistration(oneCT, user, nonce, signature),
            "AccountRegistrar: Invalid signature"
        );
        accountMapping[user].oneCT = oneCT;
        emit RegisterAccount(user, accountMapping[user].oneCT, nonce);
    }

    function deregisterAccount(
        address user,
        bytes memory signature
    ) external onlyRole(ADMIN_ROLE) {
        if (accountMapping[user].oneCT == address(0)) {
            return;
        }
        uint256 nonce = accountMapping[user].nonce;
        require(
            Validator.verifyUserDeregistration(user, nonce, signature),
            "AccountRegistrar: Invalid signature"
        );
        accountMapping[user] = AccountMapping({
            nonce: nonce + 1,
            oneCT: address(0)
        });
        emit DeregisterAccount(user, nonce + 1);
    }
}
