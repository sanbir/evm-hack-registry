// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.5;

interface IUniswapV3Pool {
    function tickSpacing() external returns (int24);

    function slot0() external returns (uint160, int24, uint16, uint16, uint16, uint8, bool);

    function feeGrowthGlobal0X128() external view returns (uint256);

    function feeGrowthGlobal1X128() external view returns (uint256);

    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}
