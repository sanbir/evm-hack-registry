// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/**
 * @title IFomoVault
 * @notice External-facing interface for the FOMO sub-protocol vault. Holds the FOMO
 *         pool's WHALE balance, the timer/lastLpAdder state, and exposes a narrow
 *         hot-path entry (`notifyTrade`) plus an LP-event entry (`notifyLpAdd`)
 *         that WHALE calls once per `_update` qualifying event.
 *
 * Funding model: tax-routing in WHALE transfers the FOMO share directly from the
 * trader to this vault's address (Layer 9 of `_update`). The vault is registered
 * as a system address in WHALE, so the inbound super._update is plain ERC20 with
 * no further pipeline interaction. Pool size is read live as
 * `WHALE.rawBalanceOf(fomoVault)`.
 *
 * Payout: when `_fomoSync` detects `elapsed >= timer`, the vault pays half the
 * pool to the previous LP adder via `WHALE.transfer(winner, payout)`. From=fomoVault
 * (system address) → Layer 2 short-circuits to plain super._update.
 */
interface IFomoVault {
    /// @notice Packed FOMO state. Same layout as the previous in-WHALE storage.
    struct FomoState {
        uint32 timer;        // remaining seconds until payout
        uint32 lastUpdate;   // last `_fomoSync` block timestamp
        address lastLpAdder; // current round's winner-elect (cleared on payout)
    }

    function fomoState() external view returns (uint32 timer, uint32 lastUpdate, address lastLpAdder);

    /// @notice Pool size in WHALE wei (live read of vault's WHALE balance).
    function pool() external view returns (uint256);

    /// @notice Live remaining seconds on the FOMO timer. Returns 0 when the next
    ///         qualifying event will fire `_fomoSync` → `_fomoPayout`.
    function timeRemaining() external view returns (uint256);

    /// @notice Layer 12 hot path: WHALE forwards (isBuy, isSell, value, sellPart, spotPrice)
    ///         every trade. `spotPrice` is the pre-trade USDT/WHALE spot rate (Layer 6
    ///         snapshot). The vault internally:
    ///           1. _fomoSync (advance timer; payout if elapsed).
    ///           2. If `isBuy && value*spotPrice/1e18 >= FOMO_BUY_USDT` → reduce timer
    ///              by 10s (floor at FOMO_BUY_FLOOR).
    ///           3. If `isSell && sellPart*spotPrice/1e18 >= FOMO_SELL_USDT_MIN` → extend
    ///              timer by `sellUsdt / FOMO_SELL_PER_SEC` (capped at FOMO_SELL_MAX_ADD).
    ///         No-op on plain user-to-user transfers (`!isBuy && !isSell`).
    function notifyTrade(bool isBuy, bool isSell, uint256 value, uint256 sellPart, uint256 spotPrice) external;

    /// @notice Permissionless settlement trigger. Calls internal `_fomoSync` to
    ///         advance the timer; if elapsed, fires `_fomoPayout` (transfers
    ///         half the pool to `lastLpAdder`, resets state). Lets keepers /
    ///         winners close out a round in a quiet market without producing
    ///         a qualifying buy / sell / addLp event. No-op when timer has not
    ///         elapsed or there is no winner / empty pool.
    function settle() external;

    /// @notice addLp event: gate on `valueUsdt >= FOMO_LP_USDT`. `valueUsdt` is
    ///         the per-event USDT-equivalent computed by WHALE's Layer 8c as
    ///         `min(usdtDeposit, whaleDeposit × spot)`. Fired at stage time (the
    ///         user's WHALE→pair transfer), not at hashrate-settle time, so an
    ///         addLp made just before timer expiry can still take `lastLpAdder`
    ///         in the round it was made. When passing, `_fomoSync` runs, timer
    ///         extends by 60s (capped at FOMO_MAX), and `lastLpAdder` is set
    ///         to `user`.
    function notifyLpAdd(address user, uint256 valueUsdt) external;
}
