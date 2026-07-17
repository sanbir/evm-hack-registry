// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20MetadataUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

/// @title IFlapTaxTokenV3
/// @notice Interface for FlapTaxTokenV3 — the next-generation tax token with asymmetric buy/sell rates
///         and a fixed, bidirectional dynamic liquidation threshold.
interface IFlapTaxTokenV3 is IERC20MetadataUpgradeable, IERC20PermitUpgradeable {
    /// @notice Enum to represent the state of the pool
    enum PoolState {
        BondingCurve, // state0: Token is trading on the bonding curve, no tax, no transfers to pools
        Migrating, // state1: Token is in the process of migration
        TaxEnforcedAntiFarmer, // state2: Token listed on DEX, tax applied for transfers involving any pool
        TaxEnforced, // state3: Token listed on DEX, tax applied for transfers involving mainPool
        TaxFree // state4: Token is free of tax

    }

    /// @notice Initialization parameters for FlapTaxTokenV3
    struct InitParams {
        /// @param name The name of the token
        string name;
        /// @param symbol The symbol of the token
        string symbol;
        /// @param meta The metadata of the token
        string meta;
        /// @param buyTax The buy tax rate in basis points (applied when a user buys from a pool)
        uint16 buyTax;
        /// @param sellTax The sell tax rate in basis points (applied when a user sells to a pool)
        uint16 sellTax;
        /// @param taxProcessor The address responsible for processing or receiving taxes
        address taxProcessor;
        /// @param dividendContract The address of the dividend contract for share tracking
        address dividendContract;
        /// @param quoteToken The address of the quote token for pools (WETH or any ERC20)
        address quoteToken;
        /// @param liqExpectedOutputAmount The expected output amount in each liquidation
        uint256 liqExpectedOutputAmount;
        /// @param taxDuration The duration of the tax in seconds
        uint256 taxDuration;
        /// @param pools The array of pool addresses
        address[] pools;
        /// @param v2Router The V2 router address
        address v2Router;
        /// @param antiFarmerDuration The duration of the anti-farmer tax in seconds
        uint256 antiFarmerDuration;
    }

    /// @notice Initializes the token with the given parameters
    /// @param params The initialization parameters
    function initialize(InitParams memory params) external;

    /// @notice Returns the stored PCS V2 router address
    function v2Router() external view returns (address);

    /// @notice Returns the main V2 pool address for this token
    function mainPool() external view returns (address);

    /// @notice Returns the minimum liquidation threshold (immutable in implementation)
    function MIN_LIQ_THRESHOLD() external view returns (uint256);

    /// @notice Returns the starting liquidation threshold (immutable in implementation)
    function START_LIQ_THRESHOLD() external view returns (uint256);

    /// @notice Returns the initial liquidation threshold stored at initialization time.
    /// This is the upper bound for threshold recovery.
    function initialLiquidationThreshold() external view returns (uint256);

    /// @notice Returns the anti-farmer duration
    function antiFarmerDuration() external view returns (uint256);

    /// @notice Returns the IPFS CID of the metadata JSON
    function metaURI() external view returns (string memory);

    /// @notice Returns the effective (worst-case) tax rate in basis points.
    /// @dev Returns max(buyTaxRate, sellTaxRate) for backward compatibility with systems
    ///      that only understand a single tax rate. Aggregators that cannot detect asymmetric
    ///      buy/sell rates will see a safe (worst-case) value and avoid under-reporting the tax.
    function taxRate() external view returns (uint16);

    /// @notice Returns the buy tax rate in basis points
    function buyTaxRate() external view returns (uint16);

    /// @notice Returns the sell tax rate in basis points
    function sellTaxRate() external view returns (uint16);

    /// @notice Returns the tax processor address
    function taxProcessor() external view returns (address);

    /// @notice Returns the dividend contract address
    function dividendContract() external view returns (address);

    /// @notice Starts the migration process (used by the Portal Contract)
    function startMigration() external;

    /// @notice Finalizes the migration process (used by the Portal Contract)
    function finalizeMigration() external;

    /// @notice Custom transfer event for easier indexing
    event TransferFlapToken(address from, address to, uint256 value);

    /// @notice Emitted when tax liquidation fails
    event TaxLiquidationError(bytes reason);

    /// @notice Custom errors
    error DividendShareUpdateFailed(address account, bytes reason);

    /// @notice Emitted when the pool state changes
    event PoolStateChanged(uint8 fromState, uint8 toState);

    /// @notice Emitted when tokens are burned for deflation
    event TokensBurned(uint256 amount);

    /// @notice Returns the current liquidation threshold
    function liquidationThreshold() external view returns (uint256);

    /// @notice Returns the current state of the pool
    function state() external view returns (PoolState);
}
