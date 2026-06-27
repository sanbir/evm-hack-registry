// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

library PriceTick {
    function getTickRangeV2(uint256 priceLower, uint256 priceUpper, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        uint256 poolPriceLower;
        uint256 poolPriceUpper;
        uint256 adjLower;
        uint256 adjUpper;

        assembly {
            if iszero(and(gt(priceLower, 0), gt(priceUpper, 0))) {
                mstore(0x00, 0x08c379a0)
                mstore(0x04, 0x20)
                mstore(0x24, 15)
                mstore(0x44, "Invalid prices")
                revert(0x00, 0x64)
            }

            if lt(priceUpper, priceLower) {
                mstore(0x00, 0x08c379a0)
                mstore(0x04, 0x20)
                mstore(0x24, 34)
                mstore(0x44, "upper must >=  lower")
                revert(0x00, 0x84)
            }

            if iszero(sgt(tickSpacing, 0)) {
                mstore(0x00, 0x08c379a0)
                mstore(0x04, 0x20)
                mstore(0x24, 22)
                mstore(0x44, "Invalid tick spacing")
                revert(0x00, 0x74)
            }

            // ---------------- 核心算式 ----------------

            let decimalAdjustment := exp(10, 18)

            poolPriceLower := div(mul(exp(10, 18), decimalAdjustment), priceUpper)
            poolPriceUpper := div(mul(exp(10, 18), decimalAdjustment), priceLower)
        }

        uint256 sqrtLower = sqrt(poolPriceLower);
        uint256 sqrtUpper = sqrt(poolPriceUpper);

        assembly {
            adjLower := div(shl(96, sqrtLower), 1000000000)
            adjUpper := div(shl(96, sqrtUpper), 1000000000)
        }
        tickLower = TickMath.getTickAtSqrtRatio(uint160(adjLower));
        tickUpper = TickMath.getTickAtSqrtRatio(uint160(adjUpper));

        tickLower = (tickLower / int24(tickSpacing)) * int24(tickSpacing);
        tickUpper = (tickUpper / int24(tickSpacing)) * int24(tickSpacing);

        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }
    }

    /// @notice 输入 WETH 价格区间（USDC 单位，1e18 精度）和 tickSpacing，返回对齐后的 tick 区间
    function getTickRange(
        uint256 priceLower, // 低价格，例如3500 （USDC/WETH，6位精度）
        uint256 priceUpper, // 高价格，例如4000 （USDC/WETH，6位精度）
        int24 tickSpacing // tick间距，例如1
    )
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        require(priceLower > 0 && priceUpper > 0, "Invalid prices");
        require(priceUpper >= priceLower, "Price upper must be >= price lower");
        require(tickSpacing > 0, "Invalid tick spacing");
        uint256 decimalAdjustment = 10 ** 18;
        uint256 poolPriceLower = (1e18 * decimalAdjustment) / priceUpper;
        uint256 poolPriceUpper = (1e18 * decimalAdjustment) / priceLower;
        tickLower = TickMath.getTickAtSqrtRatio(uint160((sqrt(poolPriceLower) * (1 << 96)) / 1e9));
        tickUpper = TickMath.getTickAtSqrtRatio(uint160((sqrt(poolPriceUpper) * (1 << 96)) / 1e9));
        tickLower = (tickLower / int24(tickSpacing)) * int24(tickSpacing);
        tickUpper = (tickUpper / int24(tickSpacing)) * int24(tickSpacing);
        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        // initial guess
        uint256 xx = x;
        uint256 r0 = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r0 <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r0 <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r0 <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r0 <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r0 <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r0 <<= 2;
        }
        if (xx >= 0x8) {
            r0 <<= 1;
        }
        r = r0;
        // Newton iterations
        unchecked {
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1;
            r = (r + x / r) >> 1; // 7 iterations - plenty for 256-bit
            uint256 r1 = x / r;
            if (r1 < r) r = r1;
        }
    }
}
