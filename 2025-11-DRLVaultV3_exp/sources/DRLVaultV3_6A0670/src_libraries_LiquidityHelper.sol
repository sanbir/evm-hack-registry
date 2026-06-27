// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import ".././interfaces/IUniswapV3Pool.sol";
import ".././interfaces/IUniswapV3Factory.sol";
import ".././interfaces/INonfungiblePositionManager.sol";

library LiquidityHelper {
    uint8 public constant USDC_DECIMALS = 6;
    uint8 public constant WETH_DECIMALS = 18;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /// @notice 计算 USDC 与 WETH 在当前价格下的投入比例
    /// @param tickLower 下界 tick
    /// @param tickUpper 上界 tick
    /// @param currentTick 当前 tick（pool.slot0().tick）
    /// @return amount0Ratio USDC 所需比例（精度 1e6）
    /// @return amount1Ratio WETH 所需比例（精度 1e18）

    function getLiquidityRatio(int24 tickLower, int24 tickUpper, int24 currentTick)
        internal
        pure
        returns (uint256 amount0Ratio, uint256 amount1Ratio)
    {
        require(tickLower < tickUpper, "Invalid tick range");

        uint160 sqrtPa = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtPb = TickMath.getSqrtRatioAtTick(tickUpper);
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(currentTick);

        uint256 sqrtPaX = uint256(sqrtPa);
        uint256 sqrtPbX = uint256(sqrtPb);
        uint256 sqrtPX = uint256(sqrtP);

        if (currentTick <= tickLower) {
            amount0Ratio = 10 ** USDC_DECIMALS;
            amount1Ratio = 0;
        } else if (currentTick >= tickUpper) {
            amount0Ratio = 0;
            amount1Ratio = 10 ** WETH_DECIMALS;
        } else {
            uint256 numerator0 = FullMath.mulDiv(sqrtPbX - sqrtPX, 1e6 << 96, 1); // USDC精度
            uint256 denominator0 = FullMath.mulDiv(sqrtPX, sqrtPbX, 1); // Q96 转换回正常精度

            amount0Ratio = FullMath.mulDiv(numerator0, 1, denominator0); // WETH精度

            amount1Ratio = ((sqrtPX - sqrtPaX) * 1e18) / (1 << 96);
        }
    }

    ///@notice this function calculate the required USDC and WETH in ratio according total USDC

    function getLiquidityAmounts(
        uint256 _totalUSDC,
        uint160 sqrtPriceX96,
        uint160 sqrtRatioLowerX96,
        uint160 sqrtRatioUpperX96
    ) internal pure returns (uint256 token0DesiredAmount, uint256 token1DesiredAmount) {
        uint128 assumedL = 1e18;
        (uint256 amount0Unit, uint256 amount1Unit) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtRatioLowerX96, sqrtRatioUpperX96, assumedL);
        uint256 sqrtSq = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 totalValueInUSDC; //in USDC's nature units;

        uint256 amount1InUSDC = FullMath.mulDiv(amount1Unit, 1 << 192, sqrtSq);
        totalValueInUSDC = amount0Unit + amount1InUSDC;
        require(totalValueInUSDC > 0, "zero total value");
        uint256 keepUSDC = FullMath.mulDiv(_totalUSDC, amount0Unit, totalValueInUSDC);

        if (keepUSDC == 0) keepUSDC = 1;
        if (keepUSDC > _totalUSDC) keepUSDC = _totalUSDC;
        uint256 swapUSDC = _totalUSDC - keepUSDC;
        return (keepUSDC, swapUSDC);
    }
}
