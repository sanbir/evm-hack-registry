// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ud, add, mul, sub, div, unwrap, sqrt} from "@prb/math/src/UD60x18.sol";
import {IErrors} from "./../interfaces/IErrors.sol";
import {TransferHelper} from "Depeg-swap/contracts/libraries/TransferHelper.sol";

library LiquidityMath {
    // Adding Liquidity (Pure Function)
    // caller of this contract must ensure the both amount is already proportional in amount!
    function addLiquidity(
        uint256 reserve0, 
        uint256 reserve1, 
        uint256 totalLiquidity, 
        uint256 amount0, 
        uint256 amount1 
    )
        internal
        pure
        returns (
            uint256 newReserve0, 
            uint256 newReserve1, 
            uint256 liquidityMinted 
        )
    {
        // Calculate the liquidity tokens minted based on the added amounts and the current reserves
        if (totalLiquidity == 0) {
            // Initial liquidity provision (sqrt of product of amounts added)
            liquidityMinted = unwrap(sqrt(mul(ud(amount0), ud(amount1))));
        } else {
            // Mint liquidity proportional to the added amounts
            liquidityMinted = unwrap(div(mul((ud(amount0)), ud(totalLiquidity)), ud(reserve0)));
        }

        // Update reserves
        newReserve0 = unwrap(add(ud(reserve0), ud(amount0)));
        newReserve1 = unwrap(add(ud(reserve1), ud(amount1)));

        return (newReserve0, newReserve1, liquidityMinted);
    }

    function getProportionalAmount(uint256 amount0, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 amount1)
    {
        return unwrap(div(mul(ud(amount0), ud(reserve1)), ud(reserve0)));
    }

    // uni v2 style proportional add liquidity
    function inferOptimalAmount(
        uint256 reserve0,
        uint256 reserve1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (reserve0 == 0 && reserve1 == 0) {
            (amount0, amount1) = (amount0Desired, amount1Desired);
        } else {
            uint256 amount1Optimal = getProportionalAmount(amount0Desired, reserve0, reserve1);

            if (amount1Optimal <= amount1Desired) {
                if (amount1Optimal < amount1Min) {
                    revert IErrors.Insufficient1Amount();
                }

                (amount0, amount1) = (amount0Desired, amount1Optimal);
            } else {
                uint256 amount0Optimal = getProportionalAmount(amount1Desired, reserve1, reserve0);
                if (amount0Optimal < amount0Min || amount0Optimal > amount0Desired) {
                    revert IErrors.Insufficient0Amount();
                }
                (amount0, amount1) = (amount0Optimal, amount1Desired);
            }
        }
    }

    // Removing Liquidity (Pure Function)
    function removeLiquidity(
        uint256 reserve0, 
        uint256 reserve1, 
        uint256 totalLiquidity, 
        uint256 liquidityAmount 
    )
        internal
        pure
        returns (
            uint256 amount0, 
            uint256 amount1, 
            uint256 newReserve0, 
            uint256 newReserve1 
        )
    {
        if (liquidityAmount <= 0) {
            revert IErrors.InvalidAmount();
        }

        if (totalLiquidity <= 0) {
            revert IErrors.NotEnoughLiquidity();
        }

        // Calculate the proportion of reserves to return based on the liquidity removed
        amount0 = unwrap(div(mul(ud(liquidityAmount), ud(reserve0)), ud(totalLiquidity)));

        amount1 = unwrap(div(mul(ud(liquidityAmount), ud(reserve1)), ud(totalLiquidity)));

        // Update reserves after removing liquidity
        newReserve0 = unwrap(sub(ud(reserve0), ud(amount0)));

        newReserve1 = unwrap(sub(ud(reserve1), ud(amount1)));

        return (amount0, amount1, newReserve0, newReserve1);
    }
}
