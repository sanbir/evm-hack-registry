//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IWrappedDollarVault
/// @notice A vault that allows users to deposit and withdraw from a
/// WrappedDollarVault
/// using ParaSwap for swaps and permits for approvals, ensuring that arbitrary
/// tokens are accepted as input and USD0PP is accepted as output.
/// @author Usual Labs
interface IWrappedDollarVault is IERC4626 {
    // ########################
    // # EVENTS #
    // ########################

    /// @notice event emitted when the router is updated
    /// @param router The router address being updated
    /// @param isActive Whether the router is being activated or deactivated
    event RouterUpdated(address indexed router, bool isActive);

    /// @notice event emitted when the fee rate is updated
    /// @param oldFeeRateBps The previous fee rate in basis points
    /// @param newFeeRateBps The new fee rate in basis points
    event FeeRateUpdated(uint32 oldFeeRateBps, uint32 newFeeRateBps);

    /// @notice event emitted when harvest is called
    /// @param caller The address that called harvest
    /// @param sharesMinted The amount of shares minted to the treasury
    event Harvested(address indexed caller, uint256 sharesMinted);

    // ########################
    // # FUNCTIONS #
    // ########################

    /// @notice Pause the vault's functionality
    /// @dev Only callable by the VAULT_PAUSER_ROLE
    function pause() external;

    /// @notice Unpause the vault's functionality
    /// @dev Only callable by the VAULT_UNPAUSER_ROLE
    function unpause() external;

    /// @notice Add or remove a router
    /// @param router The router address to modify
    /// @param isActive Whether the router should be active
    /// @dev Only callable by the VAULT_ROUTER_SETTER_ROLE
    function setRouter(address router, bool isActive) external;

    /// @notice Set the fee rate in basis points
    /// @param newFeeRateBps The new fee rate in basis points
    /// @dev Only callable by the VAULT_FEE_RATE_SETTER_ROLE
    function setFeeRateBps(uint32 newFeeRateBps) external;

    /// @notice Harvest management fees by minting shares to the treasury
    /// @dev Mints shares to the treasury based on the current management fee
    /// @dev Can only be called once per day (86400 seconds)
    /// @return sharesMinted The amount of shares minted to the treasury
    function harvest() external returns (uint256 sharesMinted);

    /// @notice Returns the fee rate in basis points
    /// @return The fee rate in basis points
    function feeRateBps() external view returns (uint32);

    /// @notice Returns the state of a router
    /// @param router The router address to check
    /// @return isActive Whether the router is active
    function getRouterState(address router)
        external
        view
        returns (bool isActive);

    /// @notice Returns the number of decimals of the vault
    /// @return The number of decimals of the vault
    function decimals() external view returns (uint8);
}
