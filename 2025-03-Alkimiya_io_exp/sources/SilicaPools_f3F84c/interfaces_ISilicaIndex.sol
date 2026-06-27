// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * _    _ _    _           _
 *     / \  | | | _(_)_ __ ___ (_)_   _  __ _
 *    / _ \ | | |/ / | '_ ` _ \| | | | |/ _` |
 *   / ___ \| |   <| | | | | | | | |_| | (_| |
 *  /_/_  \_\_|_|\_\_|_| |_| |_|_|\__, |\__,_|
 *  |_ _|_ __   __| | _____  __   |___/
 *   | || '_ \ / _` |/ _ \ \/ /
 *   | || | | | (_| |  __/>  <
 *  |___|_| |_|\__,_|\___/_/\_\
 */

/// @title Silica Index Protocol
/// @author Alkimiya
/// @notice Required methods for a contract to provide an index to Silica Pools
interface ISilicaIndex {
    /// @return A name suitable for display as a page title or heading.
    /// @custom:example "Bitcoin Mining Yield"
    /// @custom:example "Lido Staked Ethereum Yield"
    /// @custom:example "Gas Costs"
    /// @custom:since 0.1.0
    function name() external view returns (string memory);

    /// @return Short name of the display units of `shares()`.
    /// @custom:example "PH/s"
    /// @custom:example "ystETH"
    /// @custom:example "kgas"
    /// @custom:since 0.1.0
    function symbol() external view returns (string memory);

    /// @return Decimal offset of `symbol()` vs indivisible units of `shares()`.
    /// @custom:example If 1 `symbol()` (e.g. "PH/s") represents
    ///                 1e15 `shares()` (e.g. H/s)
    ///                 then `decimals()` should return 15.
    /// @custom:example If 1 `symbol()` (e.g. "ystETH") represents
    ///                 1e18 `shares()` (e.g. wei)
    ///                 then `decimals()` should return 18.
    /// @custom:example If 1 `symbol()` (e.g. "kgas") represents
    ///                 1e6 `shares()` (e.g. milligas per block)
    ///                 then `decimals()` should return 6.
    /// @custom:since 0.1.0
    function decimals() external view returns (uint256);

    /// @notice Size of the position tracked by this index.
    ///         Clients SHOULD NOT assume that this value is constant.
    ///         Clients SHOULD denominate pool shares in the same denomination
    ///         as `ISilicaIndex.shares()` (see: `symbol()`, `decimals()`).
    /// @custom:example 1e15 H/s.
    /// @custom:example `ILido.getPooledEthByShares(1 ether)` stETH wei.
    /// @custom:example 1e3 milligas per block
    /// @custom:since 0.1.0
    function shares() external view returns (uint256);

    /// @notice Clients MAY transact in any token which is pegged to
    ///         `balanceToken()`, as long as the `decimals()` match.
    ///         Clients SHOULD NOT transact in a token which is not pegged to
    ///         `balanceToken()`; the resulting financial contract will not
    ///         make sense.
    /// @custom:example 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 (WBTC on mainnet)
    /// @custom:example 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84 (stETH on mainnet)
    /// @custom:example 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 (WETH on mainnet)
    /// @custom:since 0.1.0
    function balanceToken() external view returns (address);

    /// @return Tracks the balance accumulated by the `shares()`.
    /// @notice This is not required to increase over time.
    ///         Clients SHOULD have defensive programming against underflow
    ///         when taking `balance() - initialBalance`.
    /// @custom:example WBTC earned per PH/s since Jan 1, 2023.
    /// @custom:example `ILido.getPooledEthByShares(1 ether)` stETH.
    /// @custom:example Running cost to transact 1 gas every block since Jan 1, 2023.
    /// @custom:since 0.1.0
    function balance() external view returns (uint256);
}
