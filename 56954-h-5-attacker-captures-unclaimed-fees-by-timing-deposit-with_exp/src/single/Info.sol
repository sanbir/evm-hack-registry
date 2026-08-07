// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {IKodiakIsland} from "./integrations/kodiak/IKodiakIsland.sol";
import {IStationProxy} from "./IStationProxy.sol";
import {IUniswapV3Pool} from "./integrations/kodiak/IUniswapV3Pool.sol";
import {TickRange} from "./TickRange.sol";

/// Struct containing information for a Burve single pool.
struct Info {
    /// Uniswap pool.
    IUniswapV3Pool pool;
    /// Token0.
    IERC20 token0;
    /// Token1.
    IERC20 token1;
    /// Island.
    IKodiakIsland island;
    // Station proxy.
    IStationProxy stationProxy;
    /// Total nominal liquidity.
    uint128 totalNominalLiq;
    /// Total shares of nominal liquidity.
    uint256 totalShares;
    /// The n ranges.
    /// If there is an island that range lies at index 0, encoded as (0, 0).
    TickRange[] ranges;
    /// The relative liquidity for our n ranges.
    /// If there is an island that distribution lies at index 0.
    uint256[] distX96;
}
