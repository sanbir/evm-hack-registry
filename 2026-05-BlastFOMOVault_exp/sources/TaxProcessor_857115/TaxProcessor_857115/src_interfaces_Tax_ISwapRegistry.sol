// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @title ISwapRegistry
/// @notice Registry for supported single-hop swap paths used by TaxProcessor for dividend token conversions.
///         The TaxProcessor uses this registry to look up pool/DEX parameters when swapping quote tokens
///         into a custom dividend token during dispatch().
interface ISwapRegistry {
    /// @notice Pool type enum to distinguish between AMM versions
    enum PoolType {
        V2, // Uniswap V2-style constant product pool
        V3 // Uniswap V3-style concentrated liquidity pool

    }

    /// @notice Swap configuration for a token pair
    struct SwapInfo {
        /// @notice The liquidity pool address for this token pair
        address pool;
        /// @notice The DEX identifier (maps to MultiDexRouter dexId)
        uint8 dexId;
        /// @notice The fee tier for the pool (relevant for V3 pools; ignored for V2)
        uint24 feeTier;
        /// @notice Whether this is a V2 or V3 pool
        PoolType poolType;
        /// @notice Whether this swap path is currently active
        bool supported;
    }

    /// @notice Check if a swap from `fromToken` to `toToken` is eligible (liquidity check).
    /// @dev Eligibility is determined by live pool liquidity above the configured threshold.
    ///      Blacklisted tokens always return false.
    /// @param fromToken The source token address
    /// @param toToken The destination token address
    /// @return True if the swap has sufficient liquidity and is not blacklisted
    function isSwapSupported(address fromToken, address toToken) external view returns (bool);

    /// @notice Extended swap eligibility check returning detailed status information.
    /// @param fromToken The source token address
    /// @param toToken The destination token address
    /// @return supported Whether the swap is eligible (liquidity check passes and not blacklisted)
    /// @return trustStatus The trust status of the toToken (TRUST_STATUS_UNKNOWN/WHITELISTED/BLACKLISTED)
    /// @return errorReason Human-readable reason when supported == false
    function isSwapSupportedWithDetailedErrors(address fromToken, address toToken)
        external
        view
        returns (bool supported, uint8 trustStatus, string memory errorReason);

    /// @notice Get the full swap configuration for a token pair
    /// @param fromToken The source token address
    /// @param toToken The destination token address
    /// @return info The swap configuration (pool, dex, fee tier, pool type, supported flag)
    function getSwapInfo(address fromToken, address toToken) external view returns (SwapInfo memory info);

    /// @notice Returns the MultiDexRouter address used for executing swaps
    /// @dev The TaxProcessor calls this to obtain the router address for dividend token conversion.
    ///      This is an immutable value set at construction time; changing it requires a new implementation.
    function multiDexRouter() external view returns (address);

    /// @notice Returns the default liquidity threshold applied to all quote tokens that have no per-token override.
    /// @dev Immutable: set at construction time. A per-token threshold of 0 means "use defaultThreshold".
    ///      To change it, deploy a new implementation and upgrade the proxy.
    function defaultThreshold() external view returns (uint256);

    /// @notice Returns the wrapped native token address (WETH/WBNB) used for zero-address aliasing.
    /// @dev When non-zero, `address(0)` passed as `fromToken` to eligibility checks is treated as this address.
    ///      Returns `address(0)` if zero-address aliasing is not configured.
    function weth() external view returns (address);

    /// @notice Returns whether a token is blacklisted.
    /// @dev Used by TaxProcessor to skip conversion when dividendToken is blacklisted.
    /// @param token The token to check
    function isBlacklisted(address token) external view returns (bool);

    /// @notice Returns the trust status of a token (0=unknown, 1=whitelisted, 2=blacklisted).
    function getTrustStatus(address token) external view returns (uint8);

    /// @notice Register or update a swap path for a token pair
    /// @dev Only callable by the owner.
    /// @param fromToken The source token address
    /// @param toToken The destination token address
    /// @param pool The liquidity pool address
    /// @param dexId The DEX identifier (must match MultiDexRouter's DEX IDs)
    /// @param feeTier The fee tier for the pool (ignored for V2 pools)
    /// @param poolType Whether this is a V2 or V3 pool
    function setSwapPath(
        address fromToken,
        address toToken,
        address pool,
        uint8 dexId,
        uint24 feeTier,
        PoolType poolType
    ) external;

    /// @notice Remove (disable) a swap path for a token pair
    /// @dev Does not delete the entry; sets supported = false to preserve historical data.
    /// @param fromToken The source token address
    /// @param toToken The destination token address
    function removeSwapPath(address fromToken, address toToken) external;

    /// @notice Whitelist a token (trusted, no UI warning). Removes it from blacklist if present.
    /// @dev Callable by REGISTRY_ADMIN_ROLE.
    function setWhitelisted(address token) external;

    /// @notice Blacklist a token (unsafe; TaxProcessor bypasses conversion). Removes it from whitelist if present.
    /// @dev Callable by REGISTRY_ADMIN_ROLE.
    function setBlacklisted(address token) external;

    // ---------------------------------------------------------------------------
    // Quote-token allowlist (fromToken gating)
    // ---------------------------------------------------------------------------

    /// @notice Returns whether `token` is in the quote-token allowlist.
    /// @dev The allowlist is always enforced; only explicitly allowed fromTokens are eligible.
    function isAllowedQuoteToken(address token) external view returns (bool);

    /// @notice Returns the per-quote-token liquidity threshold for `token`.
    /// @dev Returns 0 when no per-token override is set; the effective threshold falls back to `defaultThreshold()`.
    function quoteTokenThreshold(address token) external view returns (uint256);

    /// @notice Add or remove a token from the quote-token allowlist.
    /// @dev Callable by REGISTRY_ADMIN_ROLE.
    function setAllowedQuoteToken(address token, bool allowed) external;

    /// @notice Set a per-token liquidity threshold for a quote token.
    /// @dev A value of 0 clears the per-token override, causing the token to fall back to `defaultThreshold()`.
    ///      Callable by REGISTRY_ADMIN_ROLE.
    function setQuoteTokenThreshold(address token, uint256 threshold) external;

    /// @notice Emitted when a swap path is registered or updated
    event SwapPathSet(
        address indexed fromToken, address indexed toToken, address pool, uint8 dexId, uint24 feeTier, PoolType poolType
    );

    /// @notice Emitted when a swap path is disabled
    event SwapPathRemoved(address indexed fromToken, address indexed toToken);

    /// @notice Emitted when a token's trust status changes
    event TokenTrustStatusSet(address indexed token, uint8 trustStatus);

    /// @notice Emitted when a token's allowlist status changes
    event QuoteTokenAllowlistUpdated(address indexed token, bool allowed);

    /// @notice Emitted when a per-quote-token liquidity threshold is set
    event QuoteTokenThresholdUpdated(address indexed token, uint256 threshold);
}
