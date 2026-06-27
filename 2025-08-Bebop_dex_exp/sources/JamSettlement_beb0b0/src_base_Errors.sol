// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;


/// @notice Thrown when solver sends less than expected to settlement contract
error InvalidOutputBalance(address token, uint256 expected, uint256 actual);

/// @notice Thrown when sending ETH via call fails
error FailedToSendEth();

/// @notice Thrown when the passed in signature is not a valid length
error InvalidSignatureLength();

/// @notice Thrown when the recovered signer is equal to the zero address
error InvalidSignature();

/// @notice Thrown when the recovered signer does not equal the claimedSigner
error InvalidSigner();

/// @notice Thrown when the recovered contract signature is incorrect
error InvalidContractSignature();

/// @notice Thrown when msg.sender is not allowed to call a function
error InvalidExecutor();

/// @notice Thrown when length of sell tokens and sell amounts are not equal
error SellTokensInvalidLength();

/// @notice Thrown when length of buy tokens and buy amounts are not equal
error BuyTokensInvalidLength();

/// @notice Thrown when order is expired
error OrderExpired();

/// @notice Thrown when nonce is already invalidated
error InvalidNonce();

/// @notice Thrown when nonce is zero
error ZeroNonce();

/// @notice Thrown when length of filled amounts is not equal to tokens length
error InvalidFilledAmountsLength();

/// @notice Thrown when filled amounts is less than previous amount
error InvalidFilledAmounts(uint256 expected, uint256 actual);

/// @notice Thrown when length of signatures array is not equal to batch length
error InvalidBatchSignaturesLength();

/// @notice Thrown when length of hooks array is not equal to batch length
error InvalidBatchHooksLength();

/// @notice Thrown when one of the orders in batch has settlement contract as receiver
error InvalidReceiverInBatch();

/// @notice Thrown when different fees are passed in batch
error DifferentFeesInBatch();

/// @notice Thrown when invalid partner address is passed
error InvalidPartnerAddress();

/// @notice Thrown when caller is not settlement contract
error InvalidCaller();

/// @notice Thrown when interactions failed
error InteractionsFailed();

/// @notice Thrown when beforeSettle hooks failed
error BeforeSettleHooksFailed();

/// @notice Thrown when beforeSettle hooks failed
error AfterSettleHooksFailed();

/// @notice Thrown for unknown blend order type
error InvalidBlendOrderType();

/// @notice Thrown when invalid fee percentage is passed
error InvalidFeePercentage();

/// @notice Thrown when interactions contain call to balance manager
error CallToBalanceManagerNotAllowed();

/// @notice Thrown when there are duplicate buy tokens in the order
error DuplicateTokens();

/// @notice Thrown when new partner-id is different from the current one
error InvalidBlendPartnerId();