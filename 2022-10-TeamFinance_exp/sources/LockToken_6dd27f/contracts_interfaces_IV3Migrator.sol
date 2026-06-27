// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.6.2;
pragma experimental ABIEncoderV2;

/// @title V3 Migrator
/// @notice Enables migration of liqudity from Uniswap v2-compatible pairs into Uniswap v3 pools
interface IV3Migrator {
    struct MigrateParams {
        address pair; // the Uniswap v2-compatible pair
        uint256 liquidityToMigrate; // expected to be balanceOf(msg.sender)
        uint8 percentageToMigrate; // represented as a numerator over 100
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Min; // must be discounted by percentageToMigrate
        uint256 amount1Min; // must be discounted by percentageToMigrate
        address recipient;
        uint256 deadline;
        bool refundAsETH;
    }

    /// @notice Migrates liquidity to v3 by burning v2 liquidity and minting a new position for v3
    /// @dev Slippage protection is enforced via `amount{0,1}Min`, which should be a discount of the expected values of
    /// the maximum amount of v3 liquidity that the v2 liquidity can get. For the special case of migrating to an
    /// out-of-range position, `amount{0,1}Min` may be set to 0, enforcing that the position remains out of range
    /// @param params The params necessary to migrate v2 liquidity, encoded as `MigrateParams` in calldata
    function migrate(MigrateParams calldata params) external;

    /// @notice Creates a new pool if it does not exist, then initializes if not initialized
    /// @dev This method can be bundled with others via IMulticall for the first action (e.g. mint) performed against a pool
    /// @param token0 The contract address of token0 of the pool
    /// @param token1 The contract address of token1 of the pool
    /// @param fee The fee amount of the v3 pool for the specified token pair
    /// @param sqrtPriceX96 The initial square root price of the pool as a Q64.96 value
    /// @return pool Returns the pool address based on the pair of tokens and fee, will return the newly created pool address if necessary
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);
}
