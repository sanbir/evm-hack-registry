// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IWhaleZapRouter
/// @notice Minimal interface WHALE cross-calls during Layer 7a settle to redirect
///         hashrate credit from the zap helper contract to the original user
///         it was acting on behalf of.
///
///         When the zap's whale.transferFrom(zap, pair, X) leg of an internal
///         addLiquidity stages `lastTransfer = WHALE_ZAP_ROUTER`, the subsequent
///         settle must credit the actual user — not the helper contract.
///         The helper exposes `pendingUser()` so WHALE can look up that address
///         within the same tx.
interface IWhaleZapRouter {
    /// @notice The user the zap helper is currently acting for, or zero when
    ///         no zap is in flight. Set at the top of `zap()`, cleared at the
    ///         bottom. WHALE reads this during Layer 7a settle to redirect the
    ///         hashrate credit when `lastTransfer == WHALE_ZAP_ROUTER`.
    function pendingUser() external view returns (address);
}
