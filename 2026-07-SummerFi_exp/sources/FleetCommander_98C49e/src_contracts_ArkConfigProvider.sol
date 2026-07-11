// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ArkConfig, ArkParams} from "../types/ArkTypes.sol";

import {IArkConfigProvider} from "../interfaces/IArkConfigProvider.sol";

import {ArkAccessManaged} from "./ArkAccessManaged.sol";

import {ConfigurationManaged} from "./ConfigurationManaged.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Percentage, PercentageUtils} from "@summerfi/percentage-solidity/contracts/PercentageUtils.sol";

/**
 * @title ArkConfigProvider
 * @author SummerFi
 * @notice This contract manages the configuration for Ark contracts.
 * @dev Inherits from IArkConfigProvider, ArkAccessManaged, and ConfigurationManaged.
 * @custom:see IArkConfigProvider
 */
abstract contract ArkConfigProvider is
    IArkConfigProvider,
    ArkAccessManaged,
    ConfigurationManaged
{
    ArkConfig public config;

    /**
     * @notice Initializes the ArkConfigProvider contract.
     * @param _params The initial parameters for the Ark configuration.
     * @dev Validates input parameters and sets up the initial configuration.
     */
    constructor(
        ArkParams memory _params
    )
        ArkAccessManaged(_params.accessManager)
        ConfigurationManaged(_params.configurationManager)
    {
        if (_params.asset == address(0)) {
            revert CannotDeployArkWithoutToken();
        }
        if (bytes(_params.name).length == 0) {
            revert CannotDeployArkWithEmptyName();
        }
        if (raft() == address(0)) {
            revert CannotDeployArkWithoutRaft();
        }
        if (
            !PercentageUtils.isPercentageInRange(
                _params.maxDepositPercentageOfTVL
            )
        ) {
            revert MaxDepositPercentageOfTVLTooHigh();
        }

        config = ArkConfig({
            asset: IERC20(_params.asset),
            commander: address(0), // Commander is initially set to address(0)
            raft: raft(),
            depositCap: _params.depositCap,
            maxRebalanceOutflow: _params.maxRebalanceOutflow,
            maxRebalanceInflow: _params.maxRebalanceInflow,
            name: _params.name,
            details: _params.details,
            requiresKeeperData: _params.requiresKeeperData,
            maxDepositPercentageOfTVL: _params.maxDepositPercentageOfTVL
        });

        // The commander address is initially set to address(0).
        // This allows the FleetCommander contract to self-register with the Ark later,
        // using the `registerFleetCommander()` function. This approach ensures that:
        // 1. The FleetCommander's address is not hardcoded during deployment.
        // 2. Only the authorized FleetCommander can register itself.
        // 3. The Ark remains flexible for potential commander changes in the future.
        // See the `registerFleetCommander()` function for the actual registration process.
    }

    /// @inheritdoc IArkConfigProvider
    function name() external view returns (string memory) {
        return config.name;
    }

    /// @inheritdoc IArkConfigProvider
    function details() external view returns (string memory) {
        return config.details;
    }

    /// @inheritdoc IArkConfigProvider
    function depositCap() external view returns (uint256) {
        return config.depositCap;
    }

    /// @inheritdoc IArkConfigProvider
    function asset() external view returns (IERC20) {
        return config.asset;
    }

    function maxDepositPercentageOfTVL() external view returns (Percentage) {
        return config.maxDepositPercentageOfTVL;
    }
    /// @inheritdoc IArkConfigProvider

    function commander() public view returns (address) {
        return config.commander;
    }

    /// @inheritdoc IArkConfigProvider
    function maxRebalanceOutflow() external view returns (uint256) {
        return config.maxRebalanceOutflow;
    }

    /// @inheritdoc IArkConfigProvider
    function maxRebalanceInflow() external view returns (uint256) {
        return config.maxRebalanceInflow;
    }

    /// @inheritdoc IArkConfigProvider
    function requiresKeeperData() external view returns (bool) {
        return config.requiresKeeperData;
    }

    /// @inheritdoc IArkConfigProvider
    function getConfig() external view returns (ArkConfig memory) {
        return config;
    }

    /// @inheritdoc IArkConfigProvider
    function setDepositCap(uint256 newDepositCap) external onlyCommander {
        config.depositCap = newDepositCap;
        emit DepositCapUpdated(newDepositCap);
    }

    /// @inheritdoc IArkConfigProvider
    function setMaxDepositPercentageOfTVL(
        Percentage newMaxDepositPercentageOfTVL
    ) external onlyCommander {
        if (
            !PercentageUtils.isPercentageInRange(newMaxDepositPercentageOfTVL)
        ) {
            revert MaxDepositPercentageOfTVLTooHigh();
        }
        config.maxDepositPercentageOfTVL = newMaxDepositPercentageOfTVL;
        emit MaxDepositPercentageOfTVLUpdated(newMaxDepositPercentageOfTVL);
    }

    /// @inheritdoc IArkConfigProvider
    function setMaxRebalanceOutflow(
        uint256 newMaxRebalanceOutflow
    ) external onlyCommander {
        config.maxRebalanceOutflow = newMaxRebalanceOutflow;
        emit MaxRebalanceOutflowUpdated(newMaxRebalanceOutflow);
    }

    /// @inheritdoc IArkConfigProvider
    function setMaxRebalanceInflow(
        uint256 newMaxRebalanceInflow
    ) external onlyCommander {
        config.maxRebalanceInflow = newMaxRebalanceInflow;
        emit MaxRebalanceInflowUpdated(newMaxRebalanceInflow);
    }

    function registerFleetCommander() external {
        if (!_hasCommanderRole()) {
            revert CallerIsNotCommander(msg.sender);
        }
        if (config.commander != address(0)) {
            revert FleetCommanderAlreadyRegistered();
        }
        config.commander = msg.sender;
        emit FleetCommanderRegistered(msg.sender);
    }

    function unregisterFleetCommander() external {
        if (_msgSender() != config.commander) {
            revert FleetCommanderNotRegistered();
        }
        config.commander = address(0);
        emit FleetCommanderUnregistered(msg.sender);
    }

    modifier onlyCommander() {
        if (_msgSender() != config.commander) {
            revert CallerIsNotCommander(_msgSender());
        }
        _;
    }
}
