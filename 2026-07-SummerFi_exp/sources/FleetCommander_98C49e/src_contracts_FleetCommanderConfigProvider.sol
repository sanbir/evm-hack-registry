// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArk} from "../interfaces/IArk.sol";
import {FleetCommanderParams} from "../types/FleetCommanderTypes.sol";
import {FleetCommanderPausable} from "./FleetCommanderPausable.sol";

import {IFleetCommanderConfigProvider} from "../interfaces/IFleetCommanderConfigProvider.sol";

import {IFleetCommanderRewardsManagerFactory} from "../interfaces/IFleetCommanderRewardsManagerFactory.sol";
import {FleetConfig} from "../types/FleetCommanderTypes.sol";
import {ConfigurationManaged} from "./ConfigurationManaged.sol";
import {FleetCommanderRewardsManager} from "./FleetCommanderRewardsManager.sol";
import {ArkParams, BufferArk} from "./arks/BufferArk.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ProtocolAccessManaged} from "@summerfi/access-contracts/contracts/ProtocolAccessManaged.sol";
import {ContractSpecificRoles, IProtocolAccessManager} from "@summerfi/access-contracts/interfaces/IProtocolAccessManager.sol";
import {Constants} from "@summerfi/constants/Constants.sol";
import {PERCENTAGE_100, Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";

/**
 * @title FleetCommanderConfigProvider
 * @author SummerFi
 * @notice This contract provides configuration management for the FleetCommander
 * @custom:see IFleetCommanderConfigProvider
 */
contract FleetCommanderConfigProvider is
    ProtocolAccessManaged,
    FleetCommanderPausable,
    ConfigurationManaged,
    IFleetCommanderConfigProvider
{
    using EnumerableSet for EnumerableSet.AddressSet;

    FleetConfig public config;
    string public details;
    EnumerableSet.AddressSet private _activeArks;

    uint256 public constant MAX_REBALANCE_OPERATIONS = 50;
    uint256 public constant INITIAL_MINIMUM_PAUSE_TIME = 2 days;

    bool public transfersEnabled;

    constructor(
        FleetCommanderParams memory params
    )
        ProtocolAccessManaged(params.accessManager)
        FleetCommanderPausable(INITIAL_MINIMUM_PAUSE_TIME)
        ConfigurationManaged(params.configurationManager)
    {
        BufferArk _bufferArk = new BufferArk(
            ArkParams({
                name: "BufferArk",
                details: "BufferArk details",
                accessManager: address(params.accessManager),
                asset: params.asset,
                configurationManager: address(params.configurationManager),
                depositCap: Constants.MAX_UINT256,
                maxRebalanceOutflow: Constants.MAX_UINT256,
                maxRebalanceInflow: Constants.MAX_UINT256,
                requiresKeeperData: false,
                maxDepositPercentageOfTVL: PERCENTAGE_100
            }),
            address(this)
        );
        emit ArkAdded(address(_bufferArk));
        config = FleetConfig({
            bufferArk: IArk(address(_bufferArk)),
            minimumBufferBalance: params.initialMinimumBufferBalance,
            depositCap: params.depositCap,
            maxRebalanceOperations: MAX_REBALANCE_OPERATIONS,
            stakingRewardsManager: IFleetCommanderRewardsManagerFactory(
                fleetCommanderRewardsManagerFactory()
            ).createRewardsManager(address(_accessManager), address(this))
        });
        details = params.details;
    }

    /**
     * @dev Modifier to restrict function access to only active Arks (excluding the buffer ark)
     * @param arkAddress The address of the Ark to check
     * @custom:internal-logic
     * - Checks if the provided arkAddress is in the _activeArks set
     * - If not found, reverts with FleetCommanderArkNotFound error
     * - If the arkAddress is the buffer ark, it will revert, due to the buffer ark being a special case
     * @custom:effects
     * - No direct state changes, but may revert the transaction
     * @custom:security-considerations
     * - Ensures that only active Arks can perform certain operations
     * - Prevents unauthorized access from inactive or non-existent Arks
     * - Critical for maintaining the integrity and security of Ark-specific operations
     */
    modifier onlyActiveArk(address arkAddress) {
        if (!_activeArks.contains(arkAddress)) {
            revert FleetCommanderArkNotFound(arkAddress);
        }
        _;
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function isArkActiveOrBufferArk(
        address arkAddress
    ) public view returns (bool) {
        return
            _activeArks.contains(arkAddress) ||
            arkAddress == address(config.bufferArk);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function arks(uint256 index) public view returns (address) {
        return _activeArks.at(index);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function getActiveArks() public view returns (address[] memory) {
        return _activeArks.values();
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function getConfig() external view override returns (FleetConfig memory) {
        return config;
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function bufferArk() external view returns (address) {
        return address(config.bufferArk);
    }

    // ARK MANAGEMENT

    ///@inheritdoc IFleetCommanderConfigProvider
    function addArk(address ark) external onlyGovernor whenNotPaused {
        _addArk(ark);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function removeArk(address ark) external onlyGovernor whenNotPaused {
        _removeArk(ark);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setArkDepositCap(
        address ark,
        uint256 newDepositCap
    ) external onlyCurator(address(this)) onlyActiveArk(ark) whenNotPaused {
        IArk(ark).setDepositCap(newDepositCap);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setArkMaxDepositPercentageOfTVL(
        address ark,
        Percentage newMaxDepositPercentageOfTVL
    ) external onlyCurator(address(this)) onlyActiveArk(ark) whenNotPaused {
        IArk(ark).setMaxDepositPercentageOfTVL(newMaxDepositPercentageOfTVL);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setArkMaxRebalanceOutflow(
        address ark,
        uint256 newMaxRebalanceOutflow
    ) external onlyCurator(address(this)) onlyActiveArk(ark) whenNotPaused {
        IArk(ark).setMaxRebalanceOutflow(newMaxRebalanceOutflow);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setArkMaxRebalanceInflow(
        address ark,
        uint256 newMaxRebalanceInflow
    ) external onlyCurator(address(this)) onlyActiveArk(ark) whenNotPaused {
        IArk(ark).setMaxRebalanceInflow(newMaxRebalanceInflow);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setMinimumBufferBalance(
        uint256 newMinimumBalance
    ) external onlyCurator(address(this)) whenNotPaused {
        config.minimumBufferBalance = newMinimumBalance;
        emit FleetCommanderminimumBufferBalanceUpdated(newMinimumBalance);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setFleetDepositCap(
        uint256 newCap
    ) external onlyCurator(address(this)) whenNotPaused {
        config.depositCap = newCap;
        emit FleetCommanderDepositCapUpdated(newCap);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function updateStakingRewardsManager()
        external
        onlyCurator(address(this))
        whenNotPaused
    {
        config.stakingRewardsManager = IFleetCommanderRewardsManagerFactory(
            fleetCommanderRewardsManagerFactory()
        ).createRewardsManager(address(_accessManager), address(this));
        emit FleetCommanderStakingRewardsUpdated(config.stakingRewardsManager);
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setMaxRebalanceOperations(
        uint256 newMaxRebalanceOperations
    ) external onlyCurator(address(this)) whenNotPaused {
        if (newMaxRebalanceOperations > MAX_REBALANCE_OPERATIONS) {
            revert FleetCommanderMaxRebalanceOperationsTooHigh(
                newMaxRebalanceOperations
            );
        }
        config.maxRebalanceOperations = newMaxRebalanceOperations;
        emit FleetCommanderMaxRebalanceOperationsUpdated(
            newMaxRebalanceOperations
        );
    }

    ///@inheritdoc IFleetCommanderConfigProvider
    function setFleetTokenTransferability()
        external
        onlyGovernor
        whenNotPaused
    {
        if (!transfersEnabled) {
            transfersEnabled = true;
            emit TransfersEnabled();
        }
    }

    // INTERNAL FUNCTIONS
    /**
     * @dev Internal function to add a new Ark to the fleet
     * @param ark The address of the Ark to be added
     * @custom:internal-logic
     * - Checks if the ark address is valid (not zero)
     * - Verifies the ark is not already active
     * - Sets the ark as active and determines its withdrawability
     * - Checks if the ark already has a commander
     * - Registers this contract as the ark's FleetCommander
     * - Adds the ark to the list of active arks
     * @custom:effects
     * - Modifies isArkActiveOrBufferArk mapping
     * - Updates the arks array
     * - Emits an ArkAdded event
     * @custom:security-considerations
     * - Ensures no duplicate arks are added
     * - Prevents adding arks that already have a commander
     * - Only callable internally, typically by privileged roles
     */
    function _addArk(address ark) internal {
        if (ark == address(0)) {
            revert FleetCommanderInvalidArkAddress();
        }
        if (isArkActiveOrBufferArk(ark)) {
            revert FleetCommanderArkAlreadyExists(ark);
        }
        if (address(IArk(ark).asset()) != IERC4626(address(this)).asset()) {
            revert FleetCommanderAssetMismatch();
        }
        IArk(ark).registerFleetCommander();
        _activeArks.add(ark);
        emit ArkAdded(ark);
    }

    /**
     * @dev Internal function to remove an Ark from the fleet
     * @param ark The address of the Ark to be removed
     * @custom:internal-logic
     * - Checks if the ark is currently active
     * - Locates and removes the ark from the active arks list
     * - Validates that the ark can be safely removed
     * - Marks the ark as inactive
     * - Unregisters this contract as the ark's FleetCommander
     * - Revokes the COMMANDER_ROLE for this contract on the ark
     * @custom:effects
     * - Modifies the isArkActiveOrBufferArk mapping
     * - Updates the arks array
     * - Changes the ark's FleetCommander status
     * - Revokes a role in the access manager
     * - Emits an ArkRemoved event
     * @custom:security-considerations
     * - Ensures only active arks can be removed
     * - Validates ark state before removal to prevent inconsistencies
     * - Only callable internally, typically by privileged roles
     */
    function _removeArk(address ark) internal onlyActiveArk(ark) {
        _validateArkRemoval(ark);
        _activeArks.remove(ark);

        IArk(ark).unregisterFleetCommander();
        _accessManager.selfRevokeContractSpecificRole(
            ContractSpecificRoles.COMMANDER_ROLE,
            address(ark)
        );
        emit ArkRemoved(ark);
    }

    /**
     * @dev Internal function to validate if an Ark can be safely removed
     * @param ark The address of the Ark to be validated for removal
     * @custom:internal-logic
     * - Checks if the ark's deposit cap is zero
     * - Verifies that the ark holds no assets
     * @custom:effects
     * - No direct state changes, but may revert the transaction
     * @custom:security-considerations
     * - Prevents removal of arks with non-zero deposit caps or assets
     * - Ensures arks are in a safe state before removal
     * - Critical for maintaining the integrity of the fleet
     */
    function _validateArkRemoval(address ark) internal view {
        IArk _ark = IArk(ark);
        if (_ark.depositCap() > 0) {
            revert FleetCommanderArkDepositCapGreaterThanZero(ark);
        }
        if (_ark.totalAssets() != 0) {
            revert FleetCommanderArkAssetsNotZero(ark);
        }
    }
}
