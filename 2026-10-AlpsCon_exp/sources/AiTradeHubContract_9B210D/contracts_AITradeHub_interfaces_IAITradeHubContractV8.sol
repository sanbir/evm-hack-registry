// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IAITradeHubContractV8 {
    enum PayoutPreference{
        TRANSFER, COMPOUND
    }
    function getStats(address wallet) external view returns  (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        int256 user_earnings,
        uint256 user_current_service_fee,
        PayoutPreference user_payout_type
    );

    function transferFrom(address tokenAddress, address from, address to, uint256 amount) external;
    function isMigrateAllowed(address wallet) external view returns (bool);
}
