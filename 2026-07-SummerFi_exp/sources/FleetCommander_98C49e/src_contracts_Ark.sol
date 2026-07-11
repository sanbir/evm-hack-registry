// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IArk} from "../interfaces/IArk.sol";
import {IFleetCommander} from "../interfaces/IFleetCommander.sol";
import {ArkConfig, ArkParams} from "../types/ArkTypes.sol";
import {ArkConfigProvider} from "./ArkConfigProvider.sol";

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Constants} from "@summerfi/constants/Constants.sol";
import {ReentrancyGuardTransient} from "@summerfi/dependencies/openzeppelin-next/ReentrancyGuardTransient.sol";

/**
 * @title Ark
 * @author SummerFi
 * @notice This contract implements the core functionality for the Ark system,
 *         handling asset boarding, disembarking, and harvesting operations.
 * @dev This is an abstract contract that should be inherited by specific Ark implementations.
 *      Inheriting contracts must implement the abstract functions defined here.
 */
abstract contract Ark is IArk, ArkConfigProvider, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(ArkParams memory _params) ArkConfigProvider(_params) {}

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Modifier to validate board data.
     * @dev This modifier calls `_validateCommonData` and `_validateBoardData` to ensure the data is valid.
     * In the base Ark contract, we use generic bytes for the data. It is the responsibility of the Ark
     * implementing contract to override the `_validateBoardData` function to provide specific validation logic.
     * @param data The data to be validated.
     */
    modifier validateBoardData(bytes calldata data) {
        _validateCommonData(data);
        _validateBoardData(data);
        _;
    }

    /**
     * @notice Modifier to validate disembark data.
     * @dev This modifier calls `_validateCommonData` and `_validateDisembarkData` to ensure the data is valid.
     * In the base Ark contract, we use generic bytes for the data. It is the responsibility of the Ark
     * implementing contract to override the `_validateDisembarkData` function to provide specific validation logic.
     * @param data The data to be validated.
     */
    modifier validateDisembarkData(bytes calldata data) {
        _validateCommonData(data);
        _validateDisembarkData(data);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IArk
    function totalAssets() external view virtual returns (uint256) {}

    /// @inheritdoc IArk
    function withdrawableTotalAssets() external view returns (uint256) {
        if (config.requiresKeeperData) {
            return 0;
        }
        return _withdrawableTotalAssets();
    }

    /// @inheritdoc IArk
    function harvest(
        bytes calldata additionalData
    )
        external
        onlyRaft
        nonReentrant
        returns (address[] memory rewardTokens, uint256[] memory rewardAmounts)
    {
        (rewardTokens, rewardAmounts) = _harvest(additionalData);
        emit ArkHarvested(rewardTokens, rewardAmounts);
    }

    /// @inheritdoc IArk
    function sweep(
        address[] memory tokens
    )
        external
        onlyRaft
        nonReentrant
        returns (address[] memory sweptTokens, uint256[] memory sweptAmounts)
    {
        sweptTokens = new address[](tokens.length);
        sweptAmounts = new uint256[](tokens.length);
        IERC20 asset = config.asset;

        address bufferArk = address(
            IFleetCommander(config.commander).bufferArk()
        );

        if (asset.balanceOf(address(this)) > 0 && address(this) != bufferArk) {
            asset.forceApprove(bufferArk, asset.balanceOf(address(this)));
            IArk(bufferArk).board(asset.balanceOf(address(this)), bytes(""));
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = IERC20(tokens[i]).balanceOf(address(this));
            if (amount > 0) {
                IERC20(tokens[i]).safeTransfer(
                    raft(),
                    IERC20(tokens[i]).balanceOf(address(this))
                );
                sweptTokens[i] = tokens[i];
                sweptAmounts[i] = amount;
            }
        }
        emit ArkSwept(sweptTokens, sweptAmounts);
    }

    /// @inheritdoc IArk
    function board(
        uint256 amount,
        bytes calldata boardData
    )
        external
        nonReentrant
        onlyAuthorizedToBoard(this.commander())
        validateBoardData(boardData)
    {
        address msgSender = msg.sender;
        IERC20 asset = config.asset;
        asset.safeTransferFrom(msgSender, address(this), amount);
        _board(amount, boardData);

        emit Boarded(msgSender, address(asset), amount);
    }

    /// @inheritdoc IArk
    function disembark(
        uint256 amount,
        bytes calldata disembarkData
    ) external onlyCommander nonReentrant validateDisembarkData(disembarkData) {
        address msgSender = msg.sender;
        IERC20 asset = config.asset;
        _disembark(amount, disembarkData);
        asset.safeTransfer(msgSender, amount);

        emit Disembarked(msgSender, address(asset), amount);
    }

    /// @inheritdoc IArk
    function move(
        uint256 amount,
        address receiverArk,
        bytes calldata boardData,
        bytes calldata disembarkData
    ) external onlyCommander validateDisembarkData(disembarkData) {
        _disembark(amount, disembarkData);

        IERC20 asset = config.asset;
        asset.forceApprove(receiverArk, amount);
        IArk(receiverArk).board(amount, boardData);

        emit Moved(address(this), receiverArk, address(asset), amount);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to get the total assets that are withdrawable
     * @dev This function should be implemented by derived contracts to define specific withdrawability logic
     * @dev The Ark is withdrawable if it doesnt require keeper data and _withdrawableTotalAssets returns a non-zero
     * value
     * @return uint256 The total assets that are withdrawable
     */
    function _withdrawableTotalAssets() internal view virtual returns (uint256);

    /**
     * @notice Internal function to handle the boarding (depositing) of assets
     * @dev This function should be implemented by derived contracts to define specific boarding logic
     * @param amount The amount of assets to board
     * @param data Additional data for boarding, interpreted by the specific Ark implementation
     */
    function _board(uint256 amount, bytes calldata data) internal virtual;

    /**
     * @notice Internal function to handle the disembarking (withdrawing) of assets
     * @dev This function should be implemented by derived contracts to define specific disembarking logic
     * @param amount The amount of assets to disembark
     * @param data Additional data for disembarking, interpreted by the specific Ark implementation
     */
    function _disembark(uint256 amount, bytes calldata data) internal virtual;

    /**
     * @notice Internal function to handle the harvesting of rewards
     * @dev This function should be implemented by derived contracts to define specific harvesting logic
     * @param additionalData Additional data for harvesting, interpreted by the specific Ark implementation
     * @return rewardTokens The addresses of the reward tokens harvested
     * @return rewardAmounts The amounts of the reward tokens harvested
     */
    function _harvest(
        bytes calldata additionalData
    )
        internal
        virtual
        returns (address[] memory rewardTokens, uint256[] memory rewardAmounts);

    /**
     * @notice Internal function to validate boarding data
     * @dev This function should be implemented by derived contracts to define specific boarding data validation
     * @param data The boarding data to validate
     */
    function _validateBoardData(bytes calldata data) internal virtual;

    /**
     * @notice Internal function to validate disembarking data
     * @dev This function should be implemented by derived contracts to define specific disembarking data validation
     * @param data The disembarking data to validate
     */
    function _validateDisembarkData(bytes calldata data) internal virtual;

    /**
     * @notice Internal function to validate the presence or absence of additional data based on withdrawal restrictions
     * @dev This function checks if the data length is consistent with the Ark's withdrawal restrictions
     * @param data The data to validate
     */
    function _validateCommonData(bytes calldata data) internal view {
        if (data.length > 0 && !config.requiresKeeperData) {
            revert CannotUseKeeperDataWhenNotRequired();
        }
        if (data.length == 0 && config.requiresKeeperData) {
            revert KeeperDataRequired();
        }
    }

    /**
     * @notice Internal function to get the balance of the Ark's asset
     * @dev This function returns the balance of the Ark's token held by this contract
     * @return The balance of the Ark's asset
     */
    function _balanceOfAsset() internal view virtual returns (uint256) {
        return config.asset.balanceOf(address(this));
    }
}
