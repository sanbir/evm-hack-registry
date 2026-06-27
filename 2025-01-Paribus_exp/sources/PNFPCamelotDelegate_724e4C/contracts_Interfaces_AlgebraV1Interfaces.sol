// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

// camelot dex uses Algebra V1.9 which is based on UniV3 but with some differences
interface IAlgebraV1Pool {
    function globalState() external view returns (uint160 price, int24 tick, uint16 feeZtO, uint16 feeOtZ, uint16 timepointIndex, uint8 communityFee, bool unlocked);

    function liquidity() external view returns (uint128);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IAlgebraV1Factory {
    function poolByPair(address tokenA, address tokenB) external view returns (address);
}
