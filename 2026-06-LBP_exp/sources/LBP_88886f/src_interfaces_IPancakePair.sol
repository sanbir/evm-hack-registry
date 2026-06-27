// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/**
 * @title IPancakePair
 * @notice Minimal PancakeSwap V2 Pair interface used by LBP
 * @dev Only the functions LBP actually calls are declared
 */
interface IPancakePair {
    // ERC20
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);

    // Pair-specific
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function kLast() external view returns (uint256);

    // Operations
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
    function skim(address to) external;
}
