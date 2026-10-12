// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/**
 * @title AmountHelpers2 Library
 * @notice A utility library for calculating token amounts and swap fees in Uniswap V4 pools.
 *
 * @dev This library provides helper functions to:
 * - Determine the maximum token0 and token1 amounts required to fully back a liquidity position 
 *   within a given tick range (`getMaxAmountInForPool2`).
 * - Compute the input/output amounts and the split of fees in specified and unspecified currencies
 *   during swaps (`computeSwapFeeAmounts`).
 */
library AmountHelpers2 {
    /// @notice the swap fee is represented in hundredths of a bip, so the max is 100%
    uint256 internal constant MAX_SWAP_FEE = 1e6;
    /// @notice 1% fee in hundredths of a bip
    uint256 internal constant FEE_PIPS = 10000; 
    
    /**
     * @notice Calculates the maximum amount of token0 and token1 required to fully back the current liquidity 
     *         in the specified tick range of a Uniswap V4 pool.
     *
     * @dev This function fetches the current pool liquidity and price, then uses the provided tick range
     *      (from `params.tickLower` to `params.tickUpper`) to compute the amount of token0 and token1 needed.
     *      The computation assumes the position spans from the current price to each tick boundary.
     *
     * - `amount0` is calculated as the amount needed to support liquidity from the current price up to the upper tick.
     * - `amount1` is calculated as the amount needed to support liquidity from the lower tick up to the current price.
     *  
     * - This is useful for simulating amount of token0 and token1 inside the pool or validating liquidity provisioning logic.
     * 
     * @param manager The IPoolManager instance to query the pool's state.
     * @param params The tick range parameters (tickLower and tickUpper) for the liquidity position.
     * @param key The PoolKey identifying the specific Uniswap V4 pool.
     *
     * @return amount0 The maximum amount of token0 required to support the current liquidity in the given range.
     * @return amount1 The maximum amount of token1 required to support the current liquidity in the given range.
     */
    function getMaxAmountInForPool2(
        IPoolManager manager,
        IPoolManager.ModifyLiquidityParams memory params,
        PoolKey memory key
    ) public view returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getLiquidity(manager, id);
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, id);

        uint160 sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(params.tickUpper);

        amount0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceX96Upper, liquidity);
        amount1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtPriceX96Lower, sqrtPriceX96, liquidity);
    }

    /**
     * @notice Computes the specified and unspecified currency fee amount as a result of swapping some amount, given the parameters of the swap
     * @param manager The pool manager to use for the swap
     * @param params The swap parameters, including the direction of the swap (zeroForOne)
     * @param key The pool key to use for the swap
     *
     * @return amountIn The amount to be swapped in, of either currency0 or currency1, based on the direction of the swap
     * @return amountOut The amount to be received, of either currency0 or currency1, based on the direction of the swap
     * @return feeAmountSpecified The fee amount in the specified currency, of either currency0 or currency1, based on the direction of the swap
     * @return feeAmountUnspecified The amount in the unspecified currency of either currency0 or currency1, based on the direction of the swap
     */
    function computeSwapFeeAmounts(
        IPoolManager manager,
        IPoolManager.SwapParams memory params,
        PoolKey memory key
    ) internal view returns (uint256 amountIn, uint256 amountOut, uint256 feeAmountSpecified, uint256 feeAmountUnspecified) {
        PoolId id = key.toId();
        uint128 liquidity = StateLibrary.getLiquidity(manager, id);
        (uint160 sqrtPriceCurrentX96,,,) = StateLibrary.getSlot0(manager, id);

        unchecked {
            int256 amount = params.amountSpecified;
            bool zeroForOne = params.zeroForOne;
            bool exactIn = params.amountSpecified < 0;

            if (exactIn) {
                // Compute uint256 amountIn as a positive value
                amountIn = uint256(-amount);

                // Get the theoretical next price after the swap
                uint160 sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtPriceCurrentX96, liquidity, amountIn, zeroForOne
                );
                
                // Based on the next price, calculate the amount out
                amountOut = zeroForOne
                    ? SqrtPriceMath.getAmount1Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);

                // Calculate the fee amounts based on amount in and amount out
                feeAmountSpecified = FullMath.mulDiv(amountIn, FEE_PIPS, MAX_SWAP_FEE);
                feeAmountUnspecified = FullMath.mulDiv(amountOut, FEE_PIPS, MAX_SWAP_FEE);

            } else {
                // Compute amountOut including the fee as a positive value
                amountOut = (uint256(amount) * MAX_SWAP_FEE) / (MAX_SWAP_FEE - FEE_PIPS);

                // Get the theoretical next price after the swap
                uint160 sqrtPriceNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtPriceCurrentX96, liquidity, amountOut, zeroForOne
                );
                
                // Based on the next price, calculate the amount in
                amountIn = zeroForOne
                    ? SqrtPriceMath.getAmount0Delta(sqrtPriceNextX96, sqrtPriceCurrentX96, liquidity, true)
                    : SqrtPriceMath.getAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);

                // Calculate the fee amounts based on amount in and amount out
                feeAmountSpecified = FullMath.mulDiv(amountOut, FEE_PIPS, MAX_SWAP_FEE);
                feeAmountUnspecified = FullMath.mulDiv(amountIn, FEE_PIPS, MAX_SWAP_FEE);
            }
        }
    }
}
