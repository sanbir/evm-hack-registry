// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArkConfigProviderErrors} from "../errors/IArkConfigProviderErrors.sol";
import {IArkAccessManaged} from "./IArkAccessManaged.sol";

import {IArkConfigProviderEvents} from "../events/IArkConfigProviderEvents.sol";
import {ArkConfig} from "../types/ArkTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title IArkConfigProvider
 * @notice Interface for configuration of Ark contracts
 * @dev Inherits from IArkAccessManaged for access control and IArkConfigProviderEvents for event definitions
 */
interface IArkConfigProvider is
    IArkAccessManaged,
    IArkConfigProviderErrors,
    IArkConfigProviderEvents
{
    /**
     * @notice Retrieves the current fleet config
     */
    function getConfig() external view returns (ArkConfig memory);

    /**
     * @dev Returns the name of the Ark.
     * @return The name of the Ark as a string.
     */
    function name() external view returns (string memory);

    /**
     * @notice Returns the details of the Ark
     * @return The details of the Ark as a string
     */
    function details() external view returns (string memory);

    /**
     * @notice Returns the deposit cap for this Ark
     * @return The maximum amount of tokens that can be deposited into the Ark
     */
    function depositCap() external view returns (uint256);

    /**
     * @notice Returns the maximum percentage of TVL that can be deposited into the Ark
     * @return The maximum percentage of TVL that can be deposited into the Ark
     */
    function maxDepositPercentageOfTVL() external view returns (Percentage);

    /**
     * @notice Returns the maximum amount that can be moved to this Ark in one rebalance
     * @return maximum amount that can be moved to this Ark in one rebalance
     */
    function maxRebalanceInflow() external view returns (uint256);

    /**
     * @notice Returns the maximum amount that can be moved from this Ark in one rebalance
     * @return maximum amount that can be moved from this Ark in one rebalance
     */
    function maxRebalanceOutflow() external view returns (uint256);

    /**
     * @notice Returns whether the Ark requires keeper data to board/disembark
     * @return true if the Ark requires keeper data, false otherwise
     */
    function requiresKeeperData() external view returns (bool);

    /**
     * @notice Returns the ERC20 token managed by this Ark
     * @return The IERC20 interface of the managed token
     */
    function asset() external view returns (IERC20);

    /**
     * @notice Returns the address of the Fleet commander managing the ark
     * @return address Address of Fleet commander managing the ark if a Commander is assigned, address(0) otherwise
     */
    function commander() external view returns (address);

    /**
     * @notice Sets a new maximum allocation for the Ark
     * @param newDepositCap The new maximum allocation amount
     */
    function setDepositCap(uint256 newDepositCap) external;

    /**
     * @notice Sets a new maximum deposit percentage of TVL for the Ark
     * @param newMaxDepositPercentageOfTVL The new maximum deposit percentage of TVL
     */
    function setMaxDepositPercentageOfTVL(
        Percentage newMaxDepositPercentageOfTVL
    ) external;

    /**
     * @notice Sets a new maximum amount that can be moved from the Ark in one rebalance
     * @param newMaxRebalanceOutflow The new maximum amount that can be moved from the Ark
     */
    function setMaxRebalanceOutflow(uint256 newMaxRebalanceOutflow) external;

    /**
     * @notice Sets a new maximum amount that can be moved to the Ark in one rebalance
     * @param newMaxRebalanceInflow The new maximum amount that can be moved to the Ark
     */
    function setMaxRebalanceInflow(uint256 newMaxRebalanceInflow) external;

    /**
     * @notice Registers the Fleet commander for the Ark
     * @dev This function is used to register the Fleet commander for the Ark
     * it's called by the FleetCommander when ark is added to the fleet
     */
    function registerFleetCommander() external;

    /**
     * @notice Unregisters the Fleet commander for the Ark
     * @dev This function is used to unregister the Fleet commander for the Ark
     * it's called by the FleetCommander when ark is removed from the fleet
     * all balance checks are done within the FleetCommander
     */
    function unregisterFleetCommander() external;
}
