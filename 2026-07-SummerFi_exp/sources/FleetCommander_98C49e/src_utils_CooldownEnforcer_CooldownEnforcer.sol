// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICooldownEnforcer} from "./ICooldownEnforcer.sol";

import "./ICooldownEnforcerErrors.sol";
import "./ICooldownEnforcerEvents.sol";

/**
 * @title CooldownEnforcer
 * @custom:see ICooldownEnforcer
 */
abstract contract CooldownEnforcer is ICooldownEnforcer {
    /**
     * STATE VARIABLES
     */

    /**
     * Cooldown between actions in seconds
     */
    uint256 private _cooldown;

    /**
     * Timestamp of the last action in Epoch time (block timestamp)
     */
    uint256 private _lastActionTimestamp;

    /**
     * @notice The minimum duration that the contract must remain paused
     */
    uint256 private constant MINIMUM_COOLDOWN_TIME_SECONDS = 1 minutes;

    /**
     * @notice The maximum duration that the contract can enforce
     */
    uint256 private constant MAXIMUM_COOLDOWN_TIME_SECONDS = 1 days;

    /**
     * CONSTRUCTOR
     */

    /**
     * @notice Initializes the cooldown period and sets the last action timestamp to the current block timestamp
     *         if required
     *
     * @param cooldown_ The cooldown period in seconds.
     * @param enforceFromNow If true, the last action timestamp is set to the current block timestamp.
     *
     * @dev The last action timestamp is set to the current block timestamp if enforceFromNow is true,
     *      otherwise it is set to 0 signaling that the cooldown period has not started yet.
     */
    constructor(uint256 cooldown_, bool enforceFromNow) {
        if (cooldown_ < MINIMUM_COOLDOWN_TIME_SECONDS) {
            revert CooldownEnforcerCooldownTooShort();
        }
        if (cooldown_ > MAXIMUM_COOLDOWN_TIME_SECONDS) {
            revert CooldownEnforcerCooldownTooLong();
        }

        _cooldown = cooldown_;

        if (enforceFromNow) {
            _lastActionTimestamp = block.timestamp;
        }
    }

    /**
     * MODIFIERS
     */

    /**
     * @notice Modifier to enforce the cooldown period between actions.
     *
     * @dev If the cooldown period has not elapsed, the function call will revert.
     *      Otherwise, the last action timestamp is updated to the current block timestamp.
     */
    modifier enforceCooldown() {
        if (block.timestamp - _lastActionTimestamp < _cooldown) {
            revert CooldownNotElapsed(
                _lastActionTimestamp,
                _cooldown,
                block.timestamp
            );
        }

        // Update the last action timestamp to the current block timestamp
        // before executing the function so it acts as a reentrancy guard
        // by not allowing a second call to execute
        _lastActionTimestamp = block.timestamp;
        _;
    }

    /**
     * VIEW FUNCTIONS
     */

    /// @inheritdoc ICooldownEnforcer
    function getCooldown() public view returns (uint256) {
        return _cooldown;
    }

    /// @inheritdoc ICooldownEnforcer
    function getLastActionTimestamp() public view returns (uint256) {
        return _lastActionTimestamp;
    }

    /**
     * INTERNAL STATE CHANGE FUNCTIONS
     */

    /**
     * @notice Updates the cooldown period.
     *
     * @param newCooldown The new cooldown period in seconds.
     *
     * @dev The function is internal so it can be wrapped with access modifiers if needed
     */
    function _updateCooldown(uint256 newCooldown) internal {
        if (newCooldown < MINIMUM_COOLDOWN_TIME_SECONDS) {
            revert CooldownEnforcerCooldownTooShort();
        }
        if (newCooldown > MAXIMUM_COOLDOWN_TIME_SECONDS) {
            revert CooldownEnforcerCooldownTooLong();
        }
        emit CooldownUpdated(_cooldown, newCooldown);

        _cooldown = newCooldown;
    }

    /**
     * @notice Resets the last action timestamp
     * @dev Allows for cooldown period to be skipped (IE after force withdrawal)
     */
    function _resetLastActionTimestamp() internal {
        _lastActionTimestamp = 0;
    }
}
