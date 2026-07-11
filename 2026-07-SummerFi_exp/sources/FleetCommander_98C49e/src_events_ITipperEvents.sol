// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

interface ITipperEvents {
    /**
     * @notice Emitted when the tip rate is updated
     * @param newTipRate The new tip rate value
     */
    event TipRateUpdated(Percentage newTipRate);

    /**
     * @notice Emitted when tips are accrued
     * @param tipAmount The amount of tips accrued in the underlying asset's smallest unit
     */
    event TipAccrued(uint256 tipAmount);

    /**
     * @notice Emitted when the tip jar address is updated
     * @param newTipJar The new address of the tip jar
     */
    event TipJarUpdated(address newTipJar);
}
