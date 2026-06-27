// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/**
 * @title IFomoVault
 * @notice External-facing interface for the FOMO sub-protocol vault. Holds the FOMO
 *         pool's LBP balance, the timer/lastLpAdder state, and exposes a narrow
 *         hot-path entry (`notifyTrade`) plus an LP-event entry (`notifyLpAdd`)
 *         that LBP calls once per `_update` qualifying event.
 *
 * Funding model: tax-routing in LBP transfers the FOMO share directly from the
 * trader to this vault's address (Layer 9 of `_update`). The vault is registered
 * as a system address in LBP, so the inbound super._update is plain ERC20 with
 * no further pipeline interaction. Pool size is read live as
 * `LBP.rawBalanceOf(fomoVault)`.
 *
 * Payout: when `_fomoSync` detects `elapsed >= timer`, the vault pays half the
 * pool to the previous LP adder via `LBP.transfer(winner, payout)`. From=fomoVault
 * (system address) → Layer 2 short-circuits to plain super._update.
 */
interface IFomoVault {
    /// @notice Packed FOMO state. Same layout as the previous in-LBP storage.
    struct FomoState {
        uint32 timer;        // remaining seconds until payout
        uint32 lastUpdate;   // last `_fomoSync` block timestamp
        address lastLpAdder; // current round's winner-elect (cleared on payout)
    }

    function fomoState() external view returns (uint32 timer, uint32 lastUpdate, address lastLpAdder);

    /// @notice Pool size in LBP wei (live read of vault's LBP balance).
    function pool() external view returns (uint256);

    /// @notice Live remaining seconds on the FOMO timer. Returns 0 when the next
    ///         qualifying event will fire `_fomoSync` → `_fomoPayout`.
    function timeRemaining() external view returns (uint256);

    /// @notice One-shot timer rebase to `block.timestamp`. Called by LBP at the
    ///         exact `openTrading` boundary to consume the constructor-set
    ///         `lastUpdate` so the first post-open event doesn't fire an empty
    ///         payout (no winner yet).
    function rebaseLastUpdate() external;

    /// @notice Layer 12 hot path: LBP forwards (isBuy, isSell, value, sellPart, spotPrice)
    ///         every trade. `spotPrice` is the pre-trade USDT/LBP spot rate (Layer 6
    ///         snapshot). The vault internally:
    ///           1. _fomoSync (advance timer; payout if elapsed).
    ///           2. If `isBuy && value*spotPrice/1e18 >= FOMO_BUY_USDT` → reduce timer
    ///              by 10s (floor at FOMO_BUY_FLOOR).
    ///           3. If `isSell && sellPart*spotPrice/1e18 >= FOMO_SELL_USDT_MIN` → extend
    ///              timer by `sellUsdt / FOMO_SELL_PER_SEC` (capped at FOMO_SELL_MAX_ADD).
    ///         No-op on plain user-to-user transfers (`!isBuy && !isSell`).
    function notifyTrade(bool isBuy, bool isSell, uint256 value, uint256 sellPart, uint256 spotPrice) external;

    /// @notice addLp event: gate on `valueUsdt >= FOMO_LP_USDT`. `valueUsdt` is
    ///         the per-event USDT-equivalent computed by LBP's Layer 8c as
    ///         `min(usdtDeposit, lbpDeposit × spot)`. Fired at stage time (the
    ///         user's LBP→pair transfer), not at hashrate-settle time, so an
    ///         addLp made just before timer expiry can still take `lastLpAdder`
    ///         in the round it was made. When passing, `_fomoSync` runs, timer
    ///         extends by 60s (capped at FOMO_MAX), and `lastLpAdder` is set
    ///         to `user`.
    function notifyLpAdd(address user, uint256 valueUsdt) external;
}
