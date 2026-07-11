// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ICooldownEnforcer
 * @notice Enforces a cooldown period between actions. It provides the basic management for a cooldown
 *            period, allows to update the cooldown period and provides a modifier to enforce the cooldown.
 */
interface ICooldownEnforcer {
    /**
     * ERRORS
     */

    /**
     * @notice Error thrown when the cooldown period is too short
     */
    error CooldownEnforcerCooldownTooShort();

    /**
     * @notice Error thrown when the cooldown period is too long
     */
    error CooldownEnforcerCooldownTooLong();

    /**
     * VIEW FUNCTIONS
     */

    /**
     * @notice Returns the cooldown period in seoonds.
     */
    function getCooldown() external view returns (uint256);

    /**
     * @notice Returns the timestamp of the last action in Epoch time (block timestamp).
     */
    function getLastActionTimestamp() external view returns (uint256);
}
