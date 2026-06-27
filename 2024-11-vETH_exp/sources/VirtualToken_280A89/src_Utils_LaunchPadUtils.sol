// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title LaunchPadUtils Contract
/// @notice This contract stores constant values used in the LaunchPad system
library LaunchPadUtils {

    /// @notice  The max amount of uint256 
    uint256 public constant MAX_AMOUNT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice Total amount of the quote token
    uint256 public constant TOTAL_AMOUNT_OF_QUOTE_TOKEN = 10**8 * 1e18;

    // Base Mainnet
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    address public constant CURVE_STABLE_NG_FACTORY = address(0);

    /// @notice The Address of pool factory on uniswap
    address public constant UNISWAP_POOL_FACTORY_ = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;

    /// @notice The Address of router on uniswap
    address public constant UNISWAP_ROUTER_ADDRESS = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;  


    // ETH Mainnet
    // address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // address public constant CURVE_STABLE_NG_FACTORY = 0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf;

    // /// @notice The Address of pool factory on uniswap
    // address public constant UNISWAP_POOL_FACTORY_ = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;

    // /// @notice The Address of router on uniswap
    // address public constant UNISWAP_ROUTER_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

}
