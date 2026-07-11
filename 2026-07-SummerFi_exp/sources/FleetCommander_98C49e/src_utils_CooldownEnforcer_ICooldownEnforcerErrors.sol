// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @notice Emitted by the modifier when the cooldown period has not elapsed.
 *
 * @param lastActionTimestamp The timestamp of the last action in Epoch time (block timestamp).
 * @param cooldown The cooldown period in seconds.
 * @param currentTimestamp The current block timestamp.
 */
error CooldownNotElapsed(
    uint256 lastActionTimestamp,
    uint256 cooldown,
    uint256 currentTimestamp
);
