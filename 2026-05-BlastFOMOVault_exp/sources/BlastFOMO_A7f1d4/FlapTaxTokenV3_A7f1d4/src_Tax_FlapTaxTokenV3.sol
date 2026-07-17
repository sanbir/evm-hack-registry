// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {ERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {IFlapTaxTokenV3} from "src/interfaces/Tax/IFlapTaxTokenV3.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITaxProcessor} from "src/interfaces/Tax/ITaxProcessor.sol";
import {IDividend} from "src/interfaces/Tax/IDividend.sol";

// revision:
//   v0.0.1: initial version (forked from FlapTaxTokenV2)

/// @notice FlapTaxTokenV3 is an ERC20 token with asymmetric buy/sell tax rates and a fixed,
///         bidirectional dynamic liquidation threshold.
/// Features:
///    - Asymmetric tax rates: separate buy and sell tax rates in basis points.
///    - Anti-farmer tax: applied to all pools (including V3 pools) during the anti-farmer period to
///                       restrict farmers from draining trading fees by providing concentrated
///                       liquidity on Uni V3.
///    - Time-dependent tax: the tax is only applied for a configurable duration, then automatically removed.
///    - Fixed Dynamic Tax Liquidation Threshold: The threshold is bidirectionally adjusted based on
///                       the `liqThresholdDirection` signal returned by the TaxProcessor after each
///                       liquidation. It can both decrease (unfavorable conditions) and recover toward
///                       `initialLiquidationThreshold` (favorable conditions).
///    - Immutable threshold limits: `MIN_LIQ_THRESHOLD` and `START_LIQ_THRESHOLD` are implementation-level
///                       immutables, allowing the protocol to adjust system-wide limits by deploying a
///                       new implementation without code changes. All clones share these values.
contract FlapTaxTokenV3 is Initializable, ERC20PermitUpgradeable, OwnableUpgradeable, IFlapTaxTokenV3 {
    using SafeERC20 for IERC20;

    /// @notice The minimum liquidation threshold — set via constructor immutable.
    ///         All clones of the same implementation share this value.
    uint256 public immutable MIN_LIQ_THRESHOLD;

    /// @notice The starting (default) liquidation threshold — set via constructor immutable.
    ///         All clones of the same implementation share this value.
    ///         Used as the default `initialLiquidationThreshold` during `initialize()`.
    uint256 public immutable START_LIQ_THRESHOLD;

    /// @notice The maximum supply of the token
    uint256 public constant maxSupply = 1e9 ether; // 1 billion tokens

    /// @notice The address of the Uniswap/PancakeSwap V2 router contract
    address public v2Router;
    /// @notice The quote token used for pools (can be WETH or any ERC20)
    address public quoteToken;
    /// @notice The expected output amount in each liquidation (stored in TaxProcessor for V3)
    uint256 public liqExpectedOutputAmount;
    /// @notice The duration of the anti-farmer tax in seconds
    uint256 public antiFarmerDuration;

    /// @notice The address of the V2 pool
    address public mainPool;
    /// @notice The address responsible for processing collected tax
    address public taxProcessor;
    /// @notice The address of the dividend contract for share tracking
    address public dividendContract;

    /// @notice The initial liquidation threshold stored at initialization time.
    ///         Acts as the upper bound for threshold recovery — the threshold can never
    ///         increase beyond this value via `_adjustLiquidationThreshold`.
    uint256 public initialLiquidationThreshold;

    /// @notice Gas-optimized struct containing all pool-related state variables
    /// @dev Packed into a single 256-bit storage slot for gas efficiency
    /// Field breakdown:
    ///   - state: 8 bits (PoolState enum)
    ///   - buyTaxRate: 16 bits (basis points, max 65535)
    ///   - sellTaxRate: 16 bits (basis points, max 65535)
    ///   - notLiquidating: 8 bits (boolean, padded to 8 bits for alignment)
    ///   - liquidationThreshold: 96 bits (supports up to ~79B tokens with 18 decimals)
    ///   - taxExpirationTime: 64 bits (timestamp, valid until year 2554)
    ///   - antiFarmerExpirationTime: 48 bits (timestamp, valid until year 9999)
    /// Total: 8 + 16 + 16 + 8 + 96 + 64 + 48 = 256 bits (exactly one storage slot)
    ///
    /// @custom:security-note CRITICAL: If the total supply limit of the token is changed
    /// to more than 1 billion ether (10^27 wei), the liquidationThreshold field type
    /// (uint96) must be revisited to ensure it can accommodate the new supply limit
    /// without causing overflow issues. Current uint96 max value: ~79,228,162,514 ether.
    struct PackedPoolState {
        uint8 state; // Current state of the pool (PoolState enum)
        uint16 buyTaxRate; // The buy tax rate in basis points (buys from a pool)
        uint16 sellTaxRate; // The sell tax rate in basis points (sells to a pool)
        bool notLiquidating; // Indicates whether contract is not in middle of tax liquidation
        uint96 liquidationThreshold; // The threshold of tokens for liquidity
        uint64 taxExpirationTime; // Timestamp when the tax expires
        uint48 antiFarmerExpirationTime; // Timestamp when the anti-farmer tax expires (uint48 = until year 9999)
    }

    /// @notice All pool-related state variables packed into a single storage slot
    PackedPoolState public poolState;

    /// @notice Include all the pools related to this token
    mapping(address => bool) public pools;

    /// @notice The metadata URI of the token
    string public override metaURI;

    /// @notice Constructor for the implementation contract.
    ///         Sets immutable threshold limits that are shared by all clones created from this implementation.
    /// @param minLiqThreshold_ The minimum liquidation threshold (floor — cannot go below this)
    /// @param startLiqThreshold_ The starting liquidation threshold (ceiling for recovery — per-token
    ///                           `initialLiquidationThreshold` defaults to this value)
    constructor(uint256 minLiqThreshold_, uint256 startLiqThreshold_) {
        MIN_LIQ_THRESHOLD = minLiqThreshold_;
        START_LIQ_THRESHOLD = startLiqThreshold_;
        _disableInitializers();
    }

    /// @notice Initializes the token with the given parameters
    /// @param params The initialization parameters
    function initialize(InitParams memory params) external override initializer {
        v2Router = params.v2Router;
        antiFarmerDuration = params.antiFarmerDuration;

        require(params.taxDuration >= antiFarmerDuration, "Tax duration must be >= anti-farmer duration");

        __ERC20_init(params.name, params.symbol);
        __ERC20Permit_init(params.name);
        __Ownable_init();

        metaURI = params.meta;
        require(params.taxProcessor != address(0), "taxProcessor required");
        taxProcessor = params.taxProcessor;
        dividendContract = params.dividendContract;

        // Store initial liquidation threshold — used as the upper bound for threshold recovery.
        // Defaults to START_LIQ_THRESHOLD (implementation-level immutable).
        initialLiquidationThreshold = START_LIQ_THRESHOLD;

        // Initialize poolState in memory first, then write to storage once
        PackedPoolState memory newPoolState = PackedPoolState({
            state: uint8(PoolState.BondingCurve),
            buyTaxRate: params.buyTax,
            sellTaxRate: params.sellTax,
            notLiquidating: true,
            liquidationThreshold: uint96(START_LIQ_THRESHOLD),
            taxExpirationTime: uint64(params.taxDuration), // stores duration initially; converted to timestamp in finalizeMigration
            antiFarmerExpirationTime: 0 // will be set in finalizeMigration
        });
        poolState = newPoolState;

        _mint(msg.sender, maxSupply);

        quoteToken = params.quoteToken;
        liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        require(params.pools.length > 0, "At least one pool address required");
        mainPool = params.pools[0];

        for (uint256 i = 0; i < params.pools.length; i++) {
            pools[params.pools[i]] = true;
        }
    }

    /// @notice Starts the migration process by transitioning the state of the pool
    function startMigration() external override onlyOwner {
        PackedPoolState memory currentPoolState = poolState;
        if (PoolState(currentPoolState.state) == PoolState.BondingCurve) {
            currentPoolState.state = uint8(PoolState.Migrating);
            poolState = currentPoolState;
            emit PoolStateChanged(uint8(PoolState.BondingCurve), currentPoolState.state);
        }
    }

    /// @notice Finalizes the migration by transitioning the state of the pool
    function finalizeMigration() external override onlyOwner {
        PackedPoolState memory currentPoolState = poolState;
        if (PoolState(currentPoolState.state) == PoolState.Migrating) {
            currentPoolState.state = uint8(PoolState.TaxEnforcedAntiFarmer);
            currentPoolState.taxExpirationTime = uint64(currentPoolState.taxExpirationTime + block.timestamp);
            currentPoolState.antiFarmerExpirationTime = uint48(block.timestamp + antiFarmerDuration);
            poolState = currentPoolState;
            emit PoolStateChanged(uint8(PoolState.Migrating), currentPoolState.state);
        }
    }

    /// @notice Internal function to perform a plain (no tax) transfer
    function _plainTransfer(address from, address to, uint256 amount) internal {
        super._transfer(from, to, amount);
    }

    /// @notice Internal function to calculate the tax amount using provided poolState
    /// @param from The address sending the tokens
    /// @param to The address receiving the tokens
    /// @param amount The amount of tokens to transfer
    /// @param currentPoolState The current pool state in memory
    /// @return The tax amount
    function _getTaxWithPoolState(address from, address to, uint256 amount, PackedPoolState memory currentPoolState)
        internal
        view
        returns (uint256)
    {
        if (currentPoolState.notLiquidating) {
            if (PoolState(currentPoolState.state) == PoolState.TaxEnforcedAntiFarmer) {
                // Apply tax if transfer involves any pool
                if (pools[from]) {
                    // Buy: tokens flowing FROM pool TO user
                    return (amount * currentPoolState.buyTaxRate) / 10000;
                } else if (pools[to]) {
                    // Sell: tokens flowing FROM user TO pool
                    return (amount * currentPoolState.sellTaxRate) / 10000;
                }
            } else if (PoolState(currentPoolState.state) == PoolState.TaxEnforced) {
                // Apply tax only if transfer involves mainPool
                if (from == mainPool) {
                    // Buy: tokens flowing from mainPool to user
                    return (amount * currentPoolState.buyTaxRate) / 10000;
                } else if (to == mainPool) {
                    // Sell: tokens flowing from user to mainPool
                    return (amount * currentPoolState.sellTaxRate) / 10000;
                }
            }
        }
        return 0;
    }

    /// @notice Internal function to calculate the tax amount (no cached poolState)
    function _getTax(address from, address to, uint256 amount) internal view returns (uint256) {
        PackedPoolState memory currentPoolState = poolState;
        return _getTaxWithPoolState(from, to, amount, currentPoolState);
    }

    /// @notice Internal function to perform a taxed transfer
    function _taxedTransfer(address from, address to, uint256 amount, uint256 tax) internal {
        uint256 remainingAmount = amount - tax;
        _plainTransfer(from, address(this), tax);
        _plainTransfer(from, to, remainingAmount);
    }

    /// @notice Overrides the _transfer function to handle tax and liquidation
    function _transfer(address from, address to, uint256 amount) internal override {
        _liquidateTax(to);

        // load poolState after liquidation
        PackedPoolState memory currentPoolState = poolState;

        PoolState currentState = PoolState(currentPoolState.state);
        if (currentState == PoolState.BondingCurve) {
            require(!pools[from] && !pools[to], "Transfers to/from pools are restricted in BondingCurve state");
            _plainTransfer(from, to, amount);
        } else if (currentState == PoolState.Migrating) {
            _plainTransfer(from, to, amount);
        } else if (currentState == PoolState.TaxEnforcedAntiFarmer || currentState == PoolState.TaxEnforced) {
            uint256 tax = _getTaxWithPoolState(from, to, amount, currentPoolState);
            if (tax > 0) {
                _taxedTransfer(from, to, amount, tax);
            } else {
                _plainTransfer(from, to, amount);
            }
        } else {
            // TaxFree state
            _plainTransfer(from, to, amount);
        }
    }

    /// @notice Internal function to liquidate the accrued tax amount
    /// @param to the recipient of the current transfer call
    function _liquidateTax(address to) internal {
        PackedPoolState memory currentPoolState = poolState;
        PoolState currentState = PoolState(currentPoolState.state);
        if (
            (currentState == PoolState.TaxEnforced || currentState == PoolState.TaxEnforcedAntiFarmer)
                && currentPoolState.notLiquidating && (to == mainPool)
        ) {
            bool stateChanged = false;

            // State transitions
            if (block.timestamp > currentPoolState.taxExpirationTime) {
                PoolState oldState = PoolState(currentPoolState.state);
                currentPoolState.state = uint8(PoolState.TaxFree);
                currentPoolState.buyTaxRate = 0;
                currentPoolState.sellTaxRate = 0;
                stateChanged = true;
                emit PoolStateChanged(uint8(oldState), currentPoolState.state);
            } else if (
                block.timestamp > currentPoolState.antiFarmerExpirationTime && currentState != PoolState.TaxEnforced
            ) {
                PoolState oldState = PoolState(currentPoolState.state);
                currentPoolState.state = uint8(PoolState.TaxEnforced);
                stateChanged = true;
                emit PoolStateChanged(uint8(oldState), currentPoolState.state);
            }

            uint256 taxAmount = balanceOf(address(this));

            if (
                taxAmount > 0
                    && (
                        PoolState(currentPoolState.state) == PoolState.TaxFree
                            || taxAmount >= currentPoolState.liquidationThreshold
                    )
            ) {
                currentPoolState.notLiquidating = false; // start liquidation

                // Write state changes to storage once
                poolState = currentPoolState;

                // process tax via TaxProcessor; capture direction for threshold adjustment
                _processTax(taxAmount);

                // Re-read poolState and update notLiquidating, then write back
                currentPoolState = poolState;
                currentPoolState.notLiquidating = true; // end of liquidation
                poolState = currentPoolState;
            } else if (stateChanged) {
                poolState = currentPoolState;
            }
        }
    }

    /// @notice Adjusts the liquidation threshold based on the directional signal from the TaxProcessor.
    /// @dev V3 fix: unlike V2, this function is actually called from `_processTax` after each liquidation.
    ///      The threshold can both decrease (price strong, sell smaller amounts more often) and recover
    ///      toward `initialLiquidationThreshold` (price weak, wait for more tokens before selling).
    /// @param direction The directional indicator from `processTaxTokens`:
    ///    > 0 → increase toward `initialLiquidationThreshold` (swap output below reference — price weak)
    ///    < 0 → decrease toward `MIN_LIQ_THRESHOLD` (swap output exceeded reference — price strong)
    ///    == 0 → no change
    function _adjustLiquidationThreshold(int8 direction) internal {
        if (direction == 0) return;

        PackedPoolState memory currentPoolState = poolState;
        uint256 threshold = currentPoolState.liquidationThreshold;

        if (direction > 0) {
            // Increase by 1% per call, up to initialLiquidationThreshold
            threshold = (threshold * 101) / 100;
            if (threshold > initialLiquidationThreshold) {
                threshold = initialLiquidationThreshold;
            }
        } else {
            // Decrease by 1% per call, down to MIN_LIQ_THRESHOLD
            threshold = (threshold * 99) / 100;
            if (threshold < MIN_LIQ_THRESHOLD) {
                threshold = MIN_LIQ_THRESHOLD;
            }
        }

        currentPoolState.liquidationThreshold = uint96(threshold);
        poolState = currentPoolState;
    }

    /// @notice Internal helper to process tax tokens via TaxProcessor
    /// @param taxAmount The amount of tax tokens to process
    /// @return success Whether the processing succeeded
    function _processTax(uint256 taxAmount) internal returns (bool) {
        if (taxAmount == 0) return true;

        // Approve TaxProcessor to pull tokens
        if (allowance(address(this), taxProcessor) < taxAmount) {
            _approve(address(this), taxProcessor, type(uint256).max);
        }

        // Call TaxProcessor.processTaxTokens; capture the directional indicator
        try ITaxProcessor(taxProcessor).processTaxTokens(taxAmount) returns (int8 direction) {
            // V3 fix: actually call _adjustLiquidationThreshold with the returned direction
            _adjustLiquidationThreshold(direction);
        } catch (bytes memory reason) {
            emit TaxLiquidationError(reason);
            // If processing failed, transfer remaining tokens directly to taxProcessor
            // to prevent them from being permanently locked here
            uint256 remainingBalance = balanceOf(address(this));
            if (remainingBalance > 0) {
                _plainTransfer(address(this), taxProcessor, remainingBalance);
            }
        }

        return true;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        // Update dividend shares if dividendContract is set
        if (dividendContract != address(0)) {
            bool shouldSkipFrom = from == address(this) || from == address(0) || from == address(0xdead)
                || from == dividendContract || pools[from];
            bool shouldSkipTo =
                to == address(this) || to == address(0) || to == address(0xdead) || to == dividendContract || pools[to];

            if (!shouldSkipFrom) {
                try IDividend(dividendContract).setShare(from, balanceOf(from)) {}
                catch (bytes memory reason) {
                    revert DividendShareUpdateFailed(from, reason);
                }
            }

            if (!shouldSkipTo) {
                try IDividend(dividendContract).setShare(to, balanceOf(to)) {}
                catch (bytes memory reason) {
                    revert DividendShareUpdateFailed(to, reason);
                }
            }
        }

        emit TransferFlapToken(from, to, amount);
    }

    // ---------------------------------------------------------------------------
    // View functions
    // ---------------------------------------------------------------------------

    /// @notice Returns the current state of the pool
    function state() external view returns (PoolState) {
        return PoolState(poolState.state);
    }

    /// @notice Returns the effective (worst-case) tax rate for backward compatibility.
    ///         Returns max(buyTaxRate, sellTaxRate).
    function taxRate() external view override returns (uint16) {
        PackedPoolState memory s = poolState;
        return s.buyTaxRate > s.sellTaxRate ? s.buyTaxRate : s.sellTaxRate;
    }

    /// @notice Returns the buy tax rate in basis points
    function buyTaxRate() external view override returns (uint16) {
        return poolState.buyTaxRate;
    }

    /// @notice Returns the sell tax rate in basis points
    function sellTaxRate() external view override returns (uint16) {
        return poolState.sellTaxRate;
    }

    /// @notice Returns the liquidation threshold
    function liquidationThreshold() external view override returns (uint256) {
        return poolState.liquidationThreshold;
    }

    /// @notice Returns the timestamp when the tax expires
    function taxExpirationTime() external view returns (uint256) {
        return poolState.taxExpirationTime;
    }

    /// @notice Returns the timestamp when the anti-farmer tax expires
    function antiFarmerExpirationTime() external view returns (uint256) {
        return poolState.antiFarmerExpirationTime;
    }

    /// @notice Returns all pool state data in a single call (gas-optimized)
    function getPoolStateData()
        external
        view
        returns (
            PoolState currentState,
            uint16 currentBuyTaxRate,
            uint16 currentSellTaxRate,
            uint256 currentLiquidationThreshold,
            uint256 currentTaxExpirationTime,
            uint256 currentAntiFarmerExpirationTime
        )
    {
        PackedPoolState memory s = poolState;
        return (
            PoolState(s.state),
            s.buyTaxRate,
            s.sellTaxRate,
            s.liquidationThreshold,
            s.taxExpirationTime,
            s.antiFarmerExpirationTime
        );
    }
}
