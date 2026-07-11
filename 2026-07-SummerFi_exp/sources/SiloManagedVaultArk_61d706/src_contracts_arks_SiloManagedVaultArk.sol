// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../Ark.sol";
import {ISiloVault} from "../../interfaces/silo/ISiloVault.sol";
import {ISiloIncentivesController, AccruedRewards} from "../../interfaces/silo/ISiloIncentivesController.sol";
import {ISiloConfig, ConfigData} from "../../interfaces/silo/ISiloConfig.sol";
import {IGaugeHookReceiver} from "../../interfaces/silo/IGaugeHookReceiver.sol";
import {ISiloVaultIncentivesModule} from "../../interfaces/silo/ISiloVaultIncentivesModule.sol";
import {StorageSlot} from "@summerfi/dependencies/openzeppelin-next/StorageSlot.sol";

error InvalidSiloAddress();
error InvalidIncentivesControllerAddress();
error InvalidGaugeAddress();

/**
 * @title SiloManagedVault
 * @notice Ark contract for managing token supply and yield generation through Silo vaults.
 * @dev Implements strategy for depositing tokens, withdrawing tokens, and claiming rewards from Silo vaults.
 */
contract SiloManagedVaultArk is Ark {
    using SafeERC20 for IERC20;
    using StorageSlot for *;

    // Storage slots for transient storage
    bytes32 private constant UNIQUE_TOKENS_ARRAY_SLOT =
        keccak256("SiloManagedVaultArk.uniqueTokens.array");
    bytes32 private constant TOKEN_AMOUNTS_SLOT =
        keccak256("SiloManagedVaultArk.tokenAmounts");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice The Silo this Ark interacts with
    ISiloVault public immutable vault;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Constructor to set up the SiloManagedVault
     * @param _vault Address of the silo
     * @param _params ArkParams struct containing necessary parameters for Ark initialization
     */
    constructor(address _vault, ArkParams memory _params) Ark(_params) {
        if (_vault == address(0)) {
            revert InvalidSiloAddress();
        }

        // Verify that the silo's asset matches the configured asset
        if (ISiloVault(_vault).asset() != _params.asset) {
            revert ERC4626AssetMismatch();
        }

        vault = ISiloVault(_vault);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IArk
     * @notice Returns the total assets managed by this Ark in the vault
     * @return assets The total balance of underlying assets held in the vault for this Ark
     */
    function totalAssets() public view override returns (uint256 assets) {
        uint256 shares = vault.balanceOf(address(this));
        if (shares > 0) {
            assets = vault.convertToAssets(shares);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to get the total assets that are withdrawable
     * @dev SiloManagedVault is always withdrawable up to maxWithdraw
     */
    function _withdrawableTotalAssets()
        internal
        view
        override
        returns (uint256 withdrawableAssets)
    {
        uint256 shares = vault.balanceOf(address(this));
        if (shares > 0) {
            withdrawableAssets = vault.maxWithdraw(address(this));
        }
    }

    /**
     * @notice Deposits assets into the vault
     * @param amount The amount of assets to deposit
     * @param /// data Additional data (unused in this implementation)
     */
    function _board(uint256 amount, bytes calldata) internal override {
        config.asset.forceApprove(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    /**
     * @notice Withdraws assets from the vault
     * @param amount The amount of assets to withdraw
     * @param /// data Additional data (unused in this implementation)
     */
    function _disembark(uint256 amount, bytes calldata) internal override {
        if (amount == totalAssets()) {
            vault.redeem(
                vault.balanceOf(address(this)),
                address(this),
                address(this)
            );
        } else {
            vault.withdraw(amount, address(this), address(this));
        }
    }

    /**
     * @notice Internal function to harvest rewards using the Silo Incentives Controller
     * @dev This function will be implemented to handle Silo-specific reward claiming
     * @return rewardTokens Array of reward token addresses
     * @return rewardAmounts Array of claimed reward amounts
     */
    function _harvest(
        bytes calldata
    )
        internal
        override
        returns (address[] memory rewardTokens, uint256[] memory rewardAmounts)
    {
        address[]
            memory incentivesControllerAddresses = ISiloVaultIncentivesModule(
                vault.INCENTIVES_MODULE()
            ).getNotificationReceivers();

        if (incentivesControllerAddresses.length == 0) {
            revert InvalidGaugeAddress();
        }

        // Initialize unique tokens length
        uint256 uniqueTokensLength;

        // Collect all rewards in a single pass
        for (uint256 i = 0; i < incentivesControllerAddresses.length; i++) {
            AccruedRewards[] memory accruedRewards = ISiloIncentivesController(
                incentivesControllerAddresses[i]
            ).claimRewards(address(this));

            for (uint256 j = 0; j < accruedRewards.length; j++) {
                address rewardToken = accruedRewards[j].rewardToken;
                uint256 amount = accruedRewards[j].amount;

                if (amount > 0) {
                    bytes32 amountSlot = _getStorageSlot(
                        TOKEN_AMOUNTS_SLOT,
                        uint256(uint160(rewardToken))
                    );
                    uint256 currentAmount = amountSlot.asUint256().tload();

                    // Check if token is newly encountered
                    if (currentAmount == 0) {
                        _getStorageSlot(
                            UNIQUE_TOKENS_ARRAY_SLOT,
                            uniqueTokensLength
                        ).asAddress().tstore(rewardToken);
                        uniqueTokensLength++;
                    }

                    // Accumulate rewards
                    amountSlot.asUint256().tstore(currentAmount + amount);
                }
            }
        }

        rewardTokens = new address[](uniqueTokensLength);
        rewardAmounts = new uint256[](uniqueTokensLength);

        for (uint256 k = 0; k < uniqueTokensLength; k++) {
            address token = _getStorageSlot(UNIQUE_TOKENS_ARRAY_SLOT, k)
                .asAddress()
                .tload();
            uint256 amount = _getStorageSlot(
                TOKEN_AMOUNTS_SLOT,
                uint256(uint160(token))
            ).asUint256().tload();

            rewardTokens[k] = token;
            rewardAmounts[k] = amount;

            // Transfer accumulated amount
            IERC20(token).safeTransfer(raft(), amount);
        }

        return (rewardTokens, rewardAmounts);
    }

    /**
     * @notice Gets a storage slot based on prefix and index
     * @param prefix The prefix for the storage slot
     * @param index The index for the storage slot
     * @return bytes32 The storage slot value
     */
    function _getStorageSlot(
        bytes32 prefix,
        uint256 index
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prefix, index));
    }

    /**
     * @notice Validates the board data
     * @dev This Ark does not require any validation for board data
     * @param /// data Additional data to validate (unused in this implementation)
     */
    function _validateBoardData(bytes calldata) internal override {}

    /**
     * @notice Validates the disembark data
     * @dev This Ark does not require any validation for disembark data
     * @param /// data Additional data to validate (unused in this implementation)
     */
    function _validateDisembarkData(bytes calldata) internal override {}
}
