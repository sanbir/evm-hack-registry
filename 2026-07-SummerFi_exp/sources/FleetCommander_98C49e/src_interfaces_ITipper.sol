// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ITipperErrors} from "../errors/ITipperErrors.sol";
import {ITipperEvents} from "../events/ITipperEvents.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title ITipper Interface
 * @notice Interface for the tip accrual functionality in the FleetCommander contract
 * @dev This interface defines the events and functions related to tip accrual and management
 */
interface ITipper is ITipperEvents, ITipperErrors {
    /**
     * @notice Get the current tip rate
     * @return The current tip rate
     * @dev A tip rate of 100 * 1e18 represents 100%
     */
    function tipRate() external view returns (Percentage);

    /**
     * @notice Get the timestamp of the last tip accrual
     * @return The Unix timestamp of when tips were last accrued
     */
    function lastTipTimestamp() external view returns (uint256);
}
