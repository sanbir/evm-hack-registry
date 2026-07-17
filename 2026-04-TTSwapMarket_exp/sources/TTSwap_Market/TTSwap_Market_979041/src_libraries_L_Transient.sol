// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {TTSwapError} from "./L_Error.sol";
/// @notice This is a temporary library that allows us to use transient storage (tstore/tload)
/// TODO: This library can be deleted when we have the transient keyword support in solidity.

library L_Transient {
    // The slot holding the Value state, transiently. bytes32(uint256(keccak256("VALUE_SLOT")) - 1)

    bytes32 constant VALUE_SLOT =
        0xcbe27d488af5b5c1b0bd8d89be6fdfeaed3ad42719044fd9b728f33df1d6f1d1;
    // The slot holding the Value state, transiently. bytes32(uint256(keccak256("DEPTH_SLOT")) - 1)
    bytes32 constant DEPTH_SLOT =
        0x87b52c29898e62efc1f9a9b00a26dcbdaee98d728c56841703077b7c0d20dee7;

    // The slot holding the Value state, transiently. bytes32(uint256(keccak256("LOCK_SLOT")) - 1)

    bytes32 constant LOCK_SLOT =
        0xe2afc7ec4dbb9bfdb1b8e8bcf21a055747c25bf2faaea9cb5a134005381f4843;

    /// @notice Sets the reentrancy lock level.
    /// @param lock 0 = unlocked, 1 = multicall context, 2 = fully locked.
    function set(uint256 lock) internal {
        assembly {
            tstore(LOCK_SLOT, lock)
        }
    }

    /// @notice Gets the current reentrancy lock level.
    /// @return lock The current lock level (0 / 1 / 2).
    function get() internal view returns (uint256 lock) {
        assembly {
            lock := tload(LOCK_SLOT)
        }
    }

    /// @notice Sets the transient ETH value balance.
    /// @param locker The amount to store.
    function setValue(uint256 locker) internal {
        assembly {
            tstore(VALUE_SLOT, locker)
        }
    }

    /// @notice Gets the transient ETH value balance.
    /// @return value The stored amount.
    function getValue() internal view returns (uint256 value) {
        assembly {
            value := tload(VALUE_SLOT)
        }
    }

    /// @notice Increases the transient ETH value balance.
    /// @param amount The amount to add.
    function increaseValue(uint256 amount) internal {
        assembly {
            tstore(VALUE_SLOT, add(tload(VALUE_SLOT), amount))
        }
    }

    /// @notice Decreases the transient ETH value balance.
    /// @param amount The amount to subtract.
    /// @dev Reverts with TTSwapError(30) if insufficient balance.
    function decreaseValue(uint256 amount) internal {
        if (amount > getValue()) revert TTSwapError(30);
        assembly {
            tstore(VALUE_SLOT, sub(tload(VALUE_SLOT), amount))
        }
    }

    /// @notice Gets the current call depth.
    /// @return step The current depth.
    function getDepth() internal view returns (uint256 step) {
        assembly {
            step := tload(DEPTH_SLOT)
        }
    }

    /// @notice Resets the call depth to 0.
    function clearDepth() internal {
        assembly {
            tstore(DEPTH_SLOT, 0)
        }
    }

    /// @notice Increments the call depth.
    function addDepth() internal {
        assembly {
            tstore(DEPTH_SLOT, add(tload(DEPTH_SLOT), 1))
        }
    }

    /// @notice Decrements the call depth.
    function subDepth() internal {
        assembly {
            tstore(DEPTH_SLOT, sub(tload(DEPTH_SLOT), 1))
        }
    }

    /// @notice Pre-execution check to manage ETH value and recursion depth.
    /// @dev If depth is 0, initializes the transient value with `msg.value`. Always increments depth.
    /// This pattern allows for tracking `msg.value` across internal multicalls or nested operations
    /// without double-counting.
    function checkbefore() internal {
        if (getDepth() == 0) {
            setValue(msg.value);
        }
        addDepth();
    }

    /// @notice Post-execution check to refund remaining ETH and manage recursion depth.
    /// @dev Decrements depth. If depth returns to 0, refunds any remaining transient ETH value to `msg.sender`.
    /// This ensures that unused ETH sent to the contract is returned to the user at the end of the transaction.
    function checkafter() internal {
        subDepth();
        uint256 amount = getValue();
        if (getDepth() == 0 && amount > 0) {
            
            setValue(0);
            bool success;
            address to = msg.sender;
            assembly {
                // Transfer the ETH and store if it succeeded or not.
                success := call(gas(), to, amount, 0, 0, 0, 0)
            }
            if (!success) revert TTSwapError(31);
        }
    }
}
