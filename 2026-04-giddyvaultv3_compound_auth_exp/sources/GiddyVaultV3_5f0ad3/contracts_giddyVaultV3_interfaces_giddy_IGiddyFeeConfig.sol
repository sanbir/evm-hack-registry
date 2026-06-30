// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

/**
 * @title IGiddyFeeConfig
 * @notice Interface for GiddyFeeConfig contract
 * @dev Provides access to fee configuration functions for strategies
 */
interface IGiddyFeeConfig {
    // ============ Structs ============

    /**
     * @dev Struct containing fee configuration for a vault
     * @param performanceFee Performance fee in basis points (on gains)
     */
    struct FeeConfig {
        uint256 performanceFee;     // Basis points (e.g., 2000 = 20%)
    }

    // ============ View Functions ============

    /**
     * @notice Get performance fee for a vault with hierarchical logic
     * Priority: vault-specific → category-specific → default
     * @param vault Address of the vault
     * @param category Category of the vault
     * @return performanceFee Performance fee in basis points
     */
    function getPerformanceFee(
        address vault,
        string calldata category
    ) external view returns (uint256 performanceFee);

    /**
     * @notice Get the fee recipient address
     * @return recipient Address that receives all performance fees
     */
    function feeRecipient() external view returns (address recipient);

    /**
     * @notice Get the default performance fee
     * @return fee Default performance fee in basis points
     */
    function defaultPerformanceFee() external view returns (uint256 fee);

    /**
     * @notice Get vault-specific performance fee
     * @param vault Address of the vault
     * @return hasCustomFee Whether the vault has custom performance fee
     * @return performanceFee Performance fee in basis points (if custom)
     */
    function getVaultPerformanceFee(address vault) external view returns (bool hasCustomFee, uint256 performanceFee);

    /**
     * @notice Get category-specific performance fee
     * @param category Category name
     * @return hasCustomFee Whether the category has custom performance fee
     * @return performanceFee Performance fee in basis points (if custom)
     */
    function getCategoryPerformanceFee(string calldata category) external view returns (bool hasCustomFee, uint256 performanceFee);

    // ============ State Variable Getters ============

    /**
     * @notice Check if a vault has custom fee configuration
     * @param vault Address of the vault
     * @return hasCustom Whether the vault has custom fee configuration
     */
    function hasVaultCustomFee(address vault) external view returns (bool hasCustom);



    /**
     * @notice Get vault fee configuration
     * @param vault Address of the vault
     * @return config Fee configuration for the vault
     */
    function vaultFeeConfigs(address vault) external view returns (FeeConfig memory config);

    /**
     * @notice Get category fee configuration
     * @param category Category name
     * @return config Fee configuration for the category
     */
    function categoryFeeConfigs(string calldata category) external view returns (FeeConfig memory config);
}
