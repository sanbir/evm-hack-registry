// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC314 {
    event AddLiquidity(uint256 _blockToUnlockLiquidity, uint256 value);

    event RemoveLiquidity(uint256 value);

    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out
    );

    function removeLiquidity() external;

    function extendLiquidityLock(uint256 _blockToUnlockLiquidity) external;

    function getReserves() external view returns (uint256, uint256);

    function getAmountOut(
        uint256 value,
        bool buy
    ) external view returns (uint256);

}