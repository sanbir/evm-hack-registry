// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IV3TwapUtilities {
  function getV3Pool(
    address v3Factory,
    address token0,
    address token1,
    uint24 poolFee
  ) external view returns (address);

  function getPoolPriceUSDX96(
    address pricePool,
    address nativeStablePool,
    address WETH9
  ) external view returns (uint256);

  function sqrtPriceX96FromPoolAndInterval(
    address pool
  ) external view returns (uint160);

  function priceX96FromSqrtPriceX96(
    uint160 sqrtPriceX96
  ) external pure returns (uint256);
}
