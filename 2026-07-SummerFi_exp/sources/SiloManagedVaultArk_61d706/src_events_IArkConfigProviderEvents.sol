// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title IArkConfigProviderEvents
 * @notice Interface for events emitted by ArkConfigProvider contracts
 */
interface IArkConfigProviderEvents {
    /**
     * @notice Emitted when the deposit cap of the Ark is updated
     * @param newCap The new deposit cap value
     */
    event DepositCapUpdated(uint256 newCap);

    /**
     * @notice Emitted when the maximum deposit percentage of TVL is updated
     * @param newMaxDepositPercentageOfTVL The new maximum deposit percentage of TVL
     */
    event MaxDepositPercentageOfTVLUpdated(
        Percentage newMaxDepositPercentageOfTVL
    );

    /**
     * @notice Emitted when the Raft address associated with the Ark is updated
     * @param newRaft The address of the new Raft
     */
    event RaftUpdated(address newRaft);

    /**
     * @notice Emitted when the maximum outflow limit for the Ark during rebalancing is updated
     * @param newMaxOutflow The new maximum amount that can be transferred out of the Ark during a rebalance
     */
    event MaxRebalanceOutflowUpdated(uint256 newMaxOutflow);

    /**
     * @notice Emitted when the maximum inflow limit for the Ark during rebalancing is updated
     * @param newMaxInflow The new maximum amount that can be transferred into the Ark during a rebalance
     */
    event MaxRebalanceInflowUpdated(uint256 newMaxInflow);

    /**
     * @notice Emitted when the Fleet Commander is registered
     * @param commander The address of the Fleet Commander
     */
    event FleetCommanderRegistered(address commander);

    /**
     * @notice Emitted when the Fleet Commander is unregistered
     * @param commander The address of the Fleet Commander
     */
    event FleetCommanderUnregistered(address commander);
}
