// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RWAConstants
/// @notice Constants for YieldCore RWA contracts
library RWAConstants {
    // ============ Basis Points ============
    /// @notice 100% in basis points
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Maximum protocol fee (10%)
    uint256 internal constant MAX_PROTOCOL_FEE = 1_000;

    /// @notice Maximum target APY (50%)
    uint256 internal constant MAX_TARGET_APY = 5_000;

    // ============ Time Constants ============
    /// @notice Seconds per year (365 days)
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Months per year
    uint256 internal constant MONTHS_PER_YEAR = 12;

    // ============ Precision Constants ============
    /// @notice High precision for ratio calculations (1e18)
    uint256 internal constant PRECISION = 1e18;

    /// @notice Minimum loan term (30 days)
    uint256 internal constant MIN_LOAN_TERM = 30 days;

    /// @notice Maximum loan term (365 days)
    uint256 internal constant MAX_LOAN_TERM = 365 days;

    // ============ Loan Constants ============
    /// @notice Minimum interest rate (1%)
    uint256 internal constant MIN_INTEREST_RATE = 100;

    /// @notice Maximum interest rate (50%)
    uint256 internal constant MAX_INTEREST_RATE = 5_000;

    /// @notice Maximum LTV ratio for loan creation (80%)
    uint256 internal constant MAX_LTV_RATIO = 8_000;

    /// @notice Maximum number of interest payment periods (36 months)
    uint256 internal constant MAX_PAYMENT_PERIODS = 36;

    /// @notice Maximum addresses per whitelist batch operation
    uint256 internal constant MAX_WHITELIST_BATCH = 100;

    /// @notice Minimum share transfer amount to prevent dust/rounding issues (1 USDC worth)
    uint256 internal constant MIN_SHARE_TRANSFER = 1e6;

    // ============ Role Definitions ============
    /// @notice Curator role - can create loans, trigger defaults
    bytes32 internal constant CURATOR_ROLE = keccak256("CURATOR_ROLE");

    /// @notice Operator role - can record repayments, deploy capital
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Pauser role - can pause/unpause contracts
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Pool Manager role - for registry access
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
}
