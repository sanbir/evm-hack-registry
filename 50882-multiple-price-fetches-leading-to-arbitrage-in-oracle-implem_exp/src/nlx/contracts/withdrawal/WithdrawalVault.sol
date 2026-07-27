// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../bank/StrictBank.sol";

// @title WithdrawalVault
// @dev Vault for withdrawals
contract WithdrawalVault is StrictBank {
    constructor(RoleStore _roleStore, DataStore _dataStore) StrictBank(_roleStore, _dataStore) {}
}
