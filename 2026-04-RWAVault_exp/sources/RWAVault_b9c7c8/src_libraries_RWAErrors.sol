// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RWAErrors
/// @notice Custom errors for YieldCore RWA contracts
library RWAErrors {
    // ============ General Errors ============
    error ZeroAddress();
    error ZeroAmount();
    error InvalidAmount();
    error Unauthorized();
    error ArrayTooLong();

    // ============ Vault Errors ============
    error VaultNotActive();
    error VaultNotRegistered();
    error VaultCapacityExceeded();
    error MinDepositNotMet();
    error InsufficientLiquidity();
    error InsufficientBalance();
    error NotWhitelisted();
    error ExceedsUserDepositCap();
    error BelowUserMinDeposit();
    error TransferTooSmall();
    error TransferLeavesTooDust();

    // ============ Phase Errors ============
    error InvalidPhase();
    error CollectionNotStarted();
    error CollectionEnded();
    error CollectionNotEnded();
    error NotMatured();
    error WithdrawalNotAvailable();
    error PeriodEndDatesNotSet();
    error PaymentDatesNotSet();
    error ArrayLengthMismatch();
    error TooEarly();

    // ============ Loan Errors ============
    error LoanNotFound();
    error LoanNotActive();
    error InvalidLoanTerm();
    error InvalidInterestRate();
    error InvalidCollateralValue();
    error RepaymentExceedsOutstanding();

    // ============ Factory Errors ============
    error InvalidVaultParams();
    error InvalidAPY();

    // ============ Registry Errors ============
    error VaultAlreadyRegistered();

    // ============ Deployment Timelock Errors ============
    error NoPendingDeployment();
    error DeploymentNotReady();
    error DeploymentAlreadyPending();
}
