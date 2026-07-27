// SPDX-License-Identifier: MIT
pragma solidity 0.5.11;

/// @dev Compatibility implementation for the exact 2020 Origin source's
/// upgradeable Initializable import.
contract Initializable {
    bool private _initialized;
    bool private _initializing;

    modifier initializer() {
        require(_initializing || !_initialized, "already initialized");
        bool wasInitializing = _initializing;
        _initializing = true;
        _initialized = true;
        _;
        _initializing = wasInitializing;
    }
}
