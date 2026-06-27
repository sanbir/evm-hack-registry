// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IThrusterFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    function yieldCut() external view returns (uint256);
    function yieldTo() external view returns (address);
    function yieldToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setYieldTo(address) external;
    function setYieldToSetter(address) external;
    function setYieldCut(uint256) external;

    function emitSync(uint112 reserve0, uint112 reserve1) external;
    function emitSwap(
        address sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external;
    function emitTransfer(address from, address to, uint256 value) external;

    function pointsAdmin() external view returns (address);
}
