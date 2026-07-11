// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IFleetCommanderConfigProviderEvents {
    /**
     * @notice Emitted when the deposit cap is updated
     * @param newCap The new deposit cap value
     */
    event FleetCommanderDepositCapUpdated(uint256 newCap);
    /**
     * @notice Emitted when a new Ark is added
     * @param ark The address of the newly added Ark
     */
    event ArkAdded(address indexed ark);

    /**
     * @notice Emitted when an Ark is removed
     * @param ark The address of the removed Ark
     */
    event ArkRemoved(address indexed ark);
    /**
     * @notice Emitted when new minimum funds buffer balance is set
     * @param newBalance New minimum funds buffer balance
     */
    event FleetCommanderminimumBufferBalanceUpdated(uint256 newBalance);

    /**
     * @notice Emitted when new max allowed rebalance operations is set
     * @param newMaxRebalanceOperations Max allowed rebalance operations
     */
    event FleetCommanderMaxRebalanceOperationsUpdated(
        uint256 newMaxRebalanceOperations
    );

    /**
     * @notice Emitted when the staking rewards contract address is updated
     * @param newStakingRewards The address of the new staking rewards contract
     */
    event FleetCommanderStakingRewardsUpdated(address newStakingRewards);

    /**
     * @notice Emitted when the transfer enabled status is updated
     */
    event TransfersEnabled();
}
