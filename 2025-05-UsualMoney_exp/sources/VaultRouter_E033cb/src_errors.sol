//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

/*
 * ########################
 * # INPUT VALIDATION ERRORS #
 * ########################
 */

/// @notice Error thrown when an address parameter is zero
error NullAddress();

/// @notice Error thrown when the fee rate is not within allowed range (0-10%)
error InvalidFeeRate();

/// @notice Error thrown when the router status update doesn't change its state
/// @param router The router address
/// @param active Whether the router is active
error SameRouterActivity(address router, bool active);

/// @notice Error thrown when the routing restrictions update doesn't change
/// state
/// @param restricted The current routing restrictions
error SameRoutingRestrictions(bool restricted);

/// @notice Error thrown when the treasury address update doesn't change the
/// address
error SameTreasury();

/// @notice Error thrown when the fee rate update doesn't change the rate
error SameFeeRate();

/// @notice Error thrown when an amount parameter is zero
error ZeroAmount();

/// @notice Error thrown when token is not an accepted input token
/// @param token The address of the invalid token
error InvalidInputToken(address token);

/// @notice Error thrown when an address parameter is invalid
error InvalidAddress();

/*
 * ########################
 * # AUTHORIZATION ERRORS #
 * ########################
 */

/// @notice Error thrown when caller is not an authorized router during
/// restricted routing
error CallerNotAuthorizedRouter();

/// @notice Error thrown when caller lacks required permissions
error NotAuthorized();

/*
 * ########################
 * # TRANSACTION ERRORS #
 * ########################
 */

/// @notice Error thrown when a permit operation fails
error PermitFailed();

/// @notice Error thrown when slippage is applied to sUSDS (not allowed)
error NoSlippageAllowedForSUSDS();

/*
 * ########################
 * # BALANCE/AMOUNT ERRORS #
 * ########################
 */

/// @notice Error thrown when the balance before a swap is insufficient
error InsufficientBalanceBeforeSwap();

/// @notice Error thrown when the amount sent in a transaction is incorrect
error IncorrectAmountSent();

/// @notice Error thrown when the amount received after a swap is below minimum
error InsufficientAmountReceivedAfterSwap();

/// @notice Error thrown when the shares received from a deposit are below
/// minimum
error InsufficientSharesReceived();

/*
 * ########################
 * # CONTRACT VALIDATION ERRORS #
 * ########################
 */

/// @notice Error thrown when the Augustus contract is not valid
error InvalidAugustus();

/// @notice Error thrown when a token doesn't support the permit function
error TokenDoesNotSupportPermit();

/*
 * ########################
 * # TIMESTAMP ERRORS #
 * ########################
 */

/// @notice Error thrown when fee rate is updated too frequently
error FeeRateUpdateTooFrequent();

/// @notice Error thrown when harvest is called too frequently
error HarvestTooFrequent();
