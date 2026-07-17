// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice Fee configuration struct (returned by feeConfig() for backward compatibility)
/// @dev Packed into a single 256-bit storage slot for gas efficiency.
/// Field breakdown:
///   - marketBps: 16 bits
///   - deflationBps: 16 bits
///   - lpBps: 16 bits
///   - dividendBps: 16 bits
///   - feeRate: 16 bits
///   - isWeth: 8 bits (boolean)
/// Total: 88 bits (fits in one storage slot)
struct PackedFeeConfig {
    uint16 marketBps;
    uint16 deflationBps;
    uint16 lpBps;
    uint16 dividendBps;
    uint16 feeRate;
    bool isWeth;
}

/// @notice Initialization parameters for TaxProcessor
/// @dev Fields added for V3 support default to zero/address(0) for backward-compatible V2 usage.
///      When creating a V2 tax token, pass zeros for all new fields below the original V2 fields.
struct TaxProcessorInitParams {
    // --- V2 fields (unchanged) ---
    address quoteToken;
    address router;
    address feeReceiver;
    address marketAddress;
    address dividendAddress;
    address taxToken;
    uint16 feeRate;
    uint16 marketBps;
    uint16 deflationBps;
    uint16 lpBps;
    uint16 dividendBps;
    // --- V3 fields (new; pass zeros for V2 tokens) ---
    /// @notice The token used for dividend distribution.
    ///         address(0) => use quoteToken (same as V2 behavior).
    ///         taxToken address => dividend in the tax token itself.
    ///         any other address => specific ERC-20 dividend token (requires SwapRegistry support).
    address dividendToken;
    /// @notice Commission receiver address (zero = commission disabled)
    address commissionReceiver;
    /// @notice Commission in bps taken from the remainder after protocol fee.
    ///         NOTE: This is NOT user-supplied — it is calculated by PortalTokenLauncher
    ///         via _commissionForTax() and passed here at initialization time.
    uint16 commissionBps;
    /// @notice The converter address authorized to execute quote->dividendToken swaps in dispatch().
    ///         Zero = not needed (used only when dividendToken != quoteToken and dividendToken != taxToken).
    address converter;
    /// @notice Reference expected output amount for liquidation threshold direction calculation.
    ///         Zero = threshold direction always returns 0 (no change), disabling the feature.
    uint256 liqExpectedOutputAmount;
}

/// @notice Fee configuration struct (V2 — backward compatible extension of PackedFeeConfig)
/// @dev Returned by feeConfigV2(). The existing feeConfig() view is unchanged.
struct PackedFeeConfigV2 {
    uint16 marketBps;
    uint16 deflationBps;
    uint16 lpBps;
    uint16 dividendBps;
    uint16 feeRate;
    bool isWeth;
    /// @notice Commission in bps taken from the remainder after protocol fee (NEW in V3)
    uint16 commissionBps;
    /// @notice The resolved dividend token address
    address dividendToken;
}

/// @notice Interface for an external tax processor that can receive tax token parts
/// and be informed about token balance changes for tracking/dividend purposes
interface ITaxProcessor {
    // --- Initialization ---

    /// @notice Initialize the tax processor with configuration parameters
    function initialize(TaxProcessorInitParams memory params) external;

    // --- Core Tax Processing ---

    /// @notice Process tax tokens by computing fees, splitting remainder, and handling distribution.
    /// @param taxAmount The total amount of tax tokens to process
    /// @return liqThresholdDirection A directional indicator for the liquidation threshold:
    ///         > 0 => increase threshold (swap output exceeded expected)
    ///         < 0 => decrease threshold (swap output was worse than expected)
    ///         == 0 => no change (output matched expected, or liqExpectedOutputAmount is zero)
    /// @dev The return value is backward-compatible: V2 tax tokens call this via `try ... {}`
    ///      and Solidity silently ignores extra return data when no return type is declared.
    function processTaxTokens(uint256 taxAmount) external returns (int8 liqThresholdDirection);

    /// @notice Process bonding curve tax by accepting quote tokens and distributing them
    function processBondingCurveTax(uint256 quoteAmount) external;

    /// @notice Dispatch accumulated balances to receivers and dividend contract.
    /// @dev When dividendToken requires a DEX swap (Case 3), only the designated converter may
    ///      trigger the swap. Non-converter callers still dispatch fee/market/commission but skip
    ///      the dividend-token swap. The dividend balance is held until the next converter call.
    function dispatch() external;

    // --- View: Addresses ---

    /// @notice Get the quote token address (WETH if isWeth, otherwise stored quoteToken)
    function getQuoteToken() external view returns (address);

    /// @notice Get WETH address
    function weth() external view returns (address);

    /// @notice Get flapBlackHole address
    function flapBlackHole() external view returns (address);

    /// @notice Get tax token address
    function taxToken() external view returns (address);

    /// @notice Get router address
    function router() external view returns (address);

    /// @notice Get fee receiver address
    function feeReceiver() external view returns (address);

    /// @notice Get market receiver address
    function marketAddress() external view returns (address);

    /// @notice Get dividend contract address
    function dividendAddress() external view returns (address);

    /// @notice Get commission receiver address (address(0) if commission disabled)
    function commissionReceiver() external view returns (address);

    /// @notice Get the converter address for MEV-protected dividend-token swaps (address(0) if not needed)
    function converter() external view returns (address);

    /// @notice Get the dividend token address (address(0) means quoteToken is used)
    function dividendToken() external view returns (address);

    /// @notice Get the SwapRegistry address (immutable, set in constructor)
    function swapRegistry() external view returns (address);

    // --- View: Balances ---

    /// @notice Get accumulated fee quote balance
    function feeQuoteBalance() external view returns (uint256);

    /// @notice Get accumulated LP quote balance
    function lpQuoteBalance() external view returns (uint256);

    /// @notice Get accumulated market quote balance
    function marketQuoteBalance() external view returns (uint256);

    /// @notice Get accumulated pending dividend quote token balance (awaiting conversion to dividend token)
    function pendingDividendQuoteTokenBalance() external view returns (uint256);

    /// @notice Get accumulated dividend quote balance
    /// @dev Deprecated: backward-compatible alias for pendingDividendQuoteTokenBalance().
    function dividendQuoteBalance() external view returns (uint256);

    /// @notice Get accumulated dividend token balance waiting to be deposited to dividend contract
    function dividendTokenBalance() external view returns (uint256);

    /// @notice Get accumulated commission quote balance
    function commissionQuoteBalance() external view returns (uint256);

    // --- View: Config ---

    /// @notice Get packed fee configuration (unchanged from V2 for backward compatibility)
    function feeConfig() external view returns (PackedFeeConfig memory);

    /// @notice Get fee configuration including commission bps (V3 extension).
    /// @dev Use this when you need the commission bps. feeConfig() is unchanged for backward compat.
    function feeConfigV2() external view returns (PackedFeeConfigV2 memory);

    /// @notice Get the commission in basis points (taken from remainder after protocol fee)
    function commissionBps() external view returns (uint16);

    /// @notice Get the reference expected output amount for liquidation threshold direction
    function liqExpectedOutputAmount() external view returns (uint256);

    /// @notice Returns true when this TaxProcessor requires a MEV-protected RPC for the converter.
    /// @dev True when dividendToken != address(0) && dividendToken != quoteToken &&
    ///      dividendToken != taxToken (Case 3 - dividend requires a DEX swap).
    ///      When true, the converter MUST call dispatch() through a MEV-protected RPC.
    function requiresMEVProtection() external view returns (bool);

    // --- View: Totals ---

    /// @notice Get total dividend tokens sent to dividend contract
    function totalDividendTokenSent() external view returns (uint256);

    /// @notice Get total quote tokens sent to dividend contract
    /// @dev Deprecated: backward-compatible alias for totalDividendTokenSent().
    ///      The returned value represents total dividend tokens sent (not just quote tokens).
    ///      Its semantic does not match its name.
    function totalQuoteSentToDividend() external view returns (uint256);

    /// @notice Get total quote tokens added to liquidity
    function totalQuoteAddedToLiquidity() external view returns (uint256);

    /// @notice Get total tax tokens added to liquidity
    function totalTokenAddedToLiquidity() external view returns (uint256);

    /// @notice Get total quote tokens sent to marketing wallet
    function totalQuoteSentToMarketing() external view returns (uint256);
}
