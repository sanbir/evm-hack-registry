// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISilicaPools} from "../interfaces/ISilicaPools.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
/**
 *      _    _ _    _           _
 *     / \  | | | _(_)_ __ ___ (_)_   _  __ _
 *    / _ \ | | |/ / | '_ ` _ \| | | | |/ _` |
 *   / ___ \| |   <| | | | | | | | |_| | (_| |
 *  /_/   \_\_|_|\_\_|_| |_| |_|_|\__, |\__,_|
 *   ____             _   __  __  |___/_   _
 *  |  _ \ ___   ___ | | |  \/  | __ _| |_| |__  ___
 *  | |_) / _ \ / _ \| | | |\/| |/ _` | __| '_ \/ __|
 *  |  __/ (_) | (_) | | | |  | | (_| | |_| | | \__ \
 *  |_|   \___/ \___/|_| |_|  |_|\__,_|\__|_| |_|___/
 */

library PoolMaths {
    /// @notice Calculate the collateral required for a given floor, cap, shares, and shareDecimals.
    /// @param floor The predetermined lower bound on the Pool’s payout.
    /// @param cap The predetermined upper bound on the Pool’s payout.
    /// @param shares The number of short and long shares to be minted by the Pool.
    /// @param shareDecimals The number of decimal places in the shares.
    /// @return The collateral required to cover the Pool's payout for the associated amount of shares.
    function collateral(bool isRoundUp, uint128 floor, uint128 cap, uint256 shares, uint256 shareDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 intermediateValue = (cap - floor) * shares;
        return isRoundUp
            ? FixedPointMathLib.divUp(intermediateValue, 10 ** shareDecimals)
            : intermediateValue / 10 ** shareDecimals;
    }

    /// @notice Function to calculate the short payout when a user calls redeem based on their shares
    /// @param shortParams The PoolParams for pool being redeemed from
    /// @param sState The PoolState for that pool
    /// @param shortSharesBalance The users balance of short shares
    /// @return payout The payout for the user
    function shortPayout(
        ISilicaPools.PoolParams memory shortParams,
        ISilicaPools.PoolState memory sState,
        uint256 shortSharesBalance
    ) internal pure returns (uint256 payout) {
        // Short payouts pay (cap - balanceChangePerShare) * collateralMinted / (cap - floor) * shortSharesBalance / totalSharesMinted
        payout = (
            (
                (uint256(shortParams.cap - sState.balanceChangePerShare) * uint256(sState.collateralMinted))
                    / uint256(shortParams.cap - shortParams.floor)
            ) * uint256(shortSharesBalance)
        ) / uint256(sState.sharesMinted);
    }

    /// @notice Function to calculate the long payout when a user calls redeem based on their shares
    /// @param longParams The PoolParams for pool being redeemed from
    /// @param sState The PoolState for that pool
    /// @param longSharesBalance The users balance of long shares
    /// @return payout The payout for the user
    function longPayout(
        ISilicaPools.PoolParams calldata longParams,
        ISilicaPools.PoolState memory sState,
        uint256 longSharesBalance
    ) internal pure returns (uint256 payout) {
        // Long payouts pay ((balanceChangePerShare - floor) * collateralMinted) / ((cap - floor) * longSharesBalance) / totalSharesMinted)
        payout = (
            (
                (uint256(sState.balanceChangePerShare - longParams.floor) * uint256(sState.collateralMinted))
                    / uint256(longParams.cap - longParams.floor)
            ) * uint256(longSharesBalance)
        ) / uint256(sState.sharesMinted);
    }

    /// @notice Function to calculate grossBalanceChangePerShare
    /// @param indexBalance The current balance of the index. The Index is a time-varying benchmark value that reflects market dynamics.
    /// @param indexInitialBalance The initial balance of the index.
    /// @param indexShares The number of shares of the index.
    /// @param indexDecimals The number of decimal places in the index.
    /// @return The gross balance change per share.
    function grossBalanceChangePerShare(
        uint256 indexBalance,
        uint256 indexInitialBalance,
        uint256 indexShares,
        uint256 indexDecimals
    ) internal pure returns (uint256) {
        require(indexShares > 0, "Index shares must be greater than zero");
        require(
            indexBalance >= indexInitialBalance, "Index balance must be greater than or equal to the initial balance"
        );
        return ((indexBalance - indexInitialBalance) * 10 ** indexDecimals) / indexShares;
    }

    /// @notice Function to calculate the balance change per share
    /// @param floor The predetermined lower bound on the Pool’s payout.
    /// @param cap The predetermined upper bound on the Pool’s payout.
    /// @param grossBalanceChangePerShare The gross balance change per share.
    /// @return The balance change per share.
    function _balanceChangePerShare(uint256 floor, uint256 cap, uint256 grossBalanceChangePerShare)
        internal
        pure
        returns (uint256)
    {
        return max(floor, min(cap, grossBalanceChangePerShare));
    }

    // diff
    function balanceChangePerShare(
        uint256 indexBalance,
        uint128 indexInitialBalance,
        uint128 indexShares,
        uint256 indexDecimals,
        uint128 floor,
        uint128 cap
    ) internal pure returns (uint256) {
        return _balanceChangePerShare(
            floor, cap, grossBalanceChangePerShare(indexBalance, indexInitialBalance, indexShares, indexDecimals)
        );
    }

    // Helper function for min
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // Helper function for max
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
