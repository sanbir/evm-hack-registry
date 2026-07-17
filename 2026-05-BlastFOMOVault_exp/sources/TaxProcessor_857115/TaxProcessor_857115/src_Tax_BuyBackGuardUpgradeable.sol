// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title BuyBackGuardUpgradeable
/// @notice Abstract contract providing buyback status tracking with gas-optimized storage
/// @dev Uses uint256 with constants instead of bool for gas efficiency:
///      - Non-zero to non-zero transitions (1 → 2 → 1) are cheaper than zero to non-zero (0 → 1 → 0)
///      - uint256 is native word size, no need for type conversion
///      Pattern follows OpenZeppelin's ReentrancyGuardUpgradeable
abstract contract BuyBackGuardUpgradeable is Initializable {
    // --- Constants ---
    uint256 private constant _NOT_BUYING_BACK = 1;
    uint256 private constant _BUYING_BACK = 2;

    // --- Storage ---
    uint256 private _buyBackStatus;

    // --- Internal Functions ---

    /// @notice Initialize the buyback guard
    /// @dev Must be called in the initializer of the inheriting contract
    function __BuyBackGuard_init() internal onlyInitializing {
        __BuyBackGuard_init_unchained();
    }

    function __BuyBackGuard_init_unchained() internal onlyInitializing {
        _buyBackStatus = _NOT_BUYING_BACK;
    }

    /// @notice Check if buyback is currently in progress
    /// @return True if buyback is in progress
    function _isBuyingBack() internal view returns (bool) {
        return _buyBackStatus == _BUYING_BACK;
    }

    // --- Modifiers ---

    /// @notice Modifier to mark buyback operations
    /// @dev Sets status to BUYING_BACK during execution, reverts to NOT_BUYING_BACK after
    modifier duringBuyBack() {
        _buyBackStatus = _BUYING_BACK;
        _;
        _buyBackStatus = _NOT_BUYING_BACK;
    }

    /// @dev This empty reserved space is put in place to allow future versions to add new
    ///      variables without shifting down storage in the inheritance chain.
    ///      See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
    uint256[49] private __gap;
}
