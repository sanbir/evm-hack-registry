// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {X128} from "Commons/Math/Ops.sol";

import {IUniswapV3Pool} from "./integrations/kodiak/IUniswapV3Pool.sol";

// For handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
// see UniswapV3 for more context https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/FixedPoint128.sol
uint256 constant Q128 = 1 << 128;

library FeeLib {
    /// View only implemention to find the fees owed to a position
    /// @param pool that we are executing on
    /// @param tickLower of the position
    /// @param tickUpper of the position
    /// @param tickCurrent of the pool
    /// @param liquidity inside of the position
    /// @param feeGrowthInside0LastX128 of the position
    /// @param feeGrowthInside1LastX128 of the position
    function viewAccumulatedFees(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128
    ) internal view returns (uint128 tokensOwed0, uint128 tokensOwed1) {
        uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
        uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

        (
            uint256 feeGrowthInside0X128,
            uint256 feeGrowthInside1X128
        ) = getFeeGrowthInside(
                pool,
                tickLower,
                tickUpper,
                tickCurrent,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128
            );

        // UniswapV3 makes the assumption that you would call collect again on overflow
        // We will make the same assumption given that (uint128).max of any token is a lot of fees
        // https://github.com/Uniswap/v3-core/blob/d8b1c635c275d2a9450bd6a78f3fa2484fef73eb/contracts/libraries/Position.sol#L60
        tokensOwed0 = uint128(
            X128.mul256(
                liquidity,
                feeGrowthInside0X128 - feeGrowthInside0LastX128
            )
        );
        tokensOwed1 = uint128(
            X128.mul256(
                liquidity,
                feeGrowthInside1X128 - feeGrowthInside1LastX128
            )
        );
    }

    /// @notice Retrieves fee growth data
    /// @notice this is adapted from the feeGrowthInside function in the UniswapV3Pool contract
    /// @notice adapted from https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/Tick.sol
    /// @param pool The operation is taking place on
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param feeGrowthGlobal0X128 The all-time global fee growth, per unit of liquidity, in token0
    /// @param feeGrowthGlobal1X128 The all-time global fee growth, per unit of liquidity, in token1
    /// @return feeGrowthInside0X128 The all-time fee growth in token0, per unit of liquidity, inside the position's tick boundaries
    /// @return feeGrowthInside1X128 The all-time fee growth in token1, per unit of liquidity, inside the position's tick boundaries
    function getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    )
        internal
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (
            ,
            ,
            uint256 lowerFeeGrowthOutside0X128,
            uint256 lowerFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickLower);
        (
            ,
            ,
            uint256 upperFeeGrowthOutside0X128,
            uint256 upperFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickUpper);

        unchecked {
            if (tickCurrent < tickLower) {
                feeGrowthInside0X128 =
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else if (tickCurrent < tickUpper) {
                feeGrowthInside0X128 =
                    feeGrowthGlobal0X128 -
                    lowerFeeGrowthOutside0X128 -
                    upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    feeGrowthGlobal1X128 -
                    lowerFeeGrowthOutside1X128 -
                    upperFeeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 =
                    upperFeeGrowthOutside0X128 -
                    lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 =
                    upperFeeGrowthOutside1X128 -
                    lowerFeeGrowthOutside1X128;
            }
        }
    }
}
