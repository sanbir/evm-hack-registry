// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC314Errors {
    error AmountOfTokensLessThanMinimumRequired(
        uint256 amount,
        uint256 minimumAmount
    );
    error AmountMustBeGreaterThanZero();
    error YouHaveNoLiquidity();
    error InsufficientLiquidity();
    error InvalidReserves();
    error ContractIsNotInitialized();
    error InsufficientLiquidityMinted();
    error SwapNotEnabled();
    error DecreasesK();
    error TransactionExpired();
    error SlippageToleranceExceeded();
    error InvalidRecipient();
    error FailedToSendNativeCurrency();
    error NativeRepaymentFailed();
    error TokenRepaymentFailed();
    error Unauthorized(address sender);
    error SupplyAlreadyMinted();
    error InvalidOwner();
    error InvalidAddress();
    error InvalidFeeRate();
    error BoughtAmountTooLow();
    error NoFeesToClaim();
    error InvalidMaxWalletPercent();
    error MaxWalletAmountExceeded();
    error AlreadyInitialized();
}
