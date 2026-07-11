// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title FleetCommanderPausable
/// @notice An abstract contract that extends OpenZeppelin's Pausable with a minimum pause time functionality
/// @dev This contract should be inherited by other contracts that require a minimum pause duration
abstract contract FleetCommanderPausable is Pausable {
    /// @notice The minimum duration that the contract must remain paused
    uint256 public minimumPauseTime;

    /// @notice The timestamp when the contract was last paused
    uint256 public pauseStartTime;

    /// @notice The minimum duration that the contract must remain paused
    uint256 constant MINIMUM_PAUSE_TIME_SECONDS = 2 days;

    /// @notice Emitted when the minimum pause time is updated
    /// @param newMinimumPauseTime The new minimum pause time value
    event MinimumPauseTimeUpdated(uint256 newMinimumPauseTime);

    /// @notice Error thrown when trying to unpause before the minimum pause time has elapsed
    error FleetCommanderPausableMinimumPauseTimeNotElapsed();

    /// @notice Error thrown when trying to set a minimum pause time that is too short
    error FleetCommanderPausableMinimumPauseTimeTooShort();

    /**
     * @notice Initializes the FleetCommanderPausable contract with a specified minimum pause time
     * @param _initialMinimumPauseTime The initial minimum pause time in seconds
     */
    constructor(uint256 _initialMinimumPauseTime) {
        if (_initialMinimumPauseTime < MINIMUM_PAUSE_TIME_SECONDS) {
            revert FleetCommanderPausableMinimumPauseTimeTooShort();
        }
        minimumPauseTime = _initialMinimumPauseTime;
        emit MinimumPauseTimeUpdated(_initialMinimumPauseTime);
    }

    /**
     * @notice Internal function to pause the contract
     * @dev Overrides the _pause function from OpenZeppelin's Pausable
     */
    function _pause() internal override {
        super._pause();
        pauseStartTime = block.timestamp;
    }

    /**
     * @notice Internal function to unpause the contract
     * @dev Overrides the _unpause function from OpenZeppelin's Pausable
     * @dev Reverts if the minimum pause time has not elapsed
     */
    function _unpause() internal override {
        if (block.timestamp < pauseStartTime + minimumPauseTime) {
            revert FleetCommanderPausableMinimumPauseTimeNotElapsed();
        }
        super._unpause();
    }

    /**
     * @notice Internal function to set a new minimum pause time
     * @param _newMinimumPauseTime The new minimum pause time in seconds
     * @dev Emits a MinimumPauseTimeUpdated event
     */
    function _setMinimumPauseTime(uint256 _newMinimumPauseTime) internal {
        if (_newMinimumPauseTime < MINIMUM_PAUSE_TIME_SECONDS) {
            revert FleetCommanderPausableMinimumPauseTimeTooShort();
        }
        minimumPauseTime = _newMinimumPauseTime;
        emit MinimumPauseTimeUpdated(_newMinimumPauseTime);
    }
}
