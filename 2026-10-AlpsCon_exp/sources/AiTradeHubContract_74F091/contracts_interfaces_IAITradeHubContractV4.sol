// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IAITradeHubContractV4 {
    enum PayoutPreference{
        NONE, COMPOUND, TRANSFER
    }
    function getStats(address wallet) external view returns  (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_paid_amount,
        uint256 user_balance,
        uint256 user_claimable_profit,
        uint256 user_current_service_fee,
        PayoutPreference user_payout_type
    );

    function getConfig() external view returns (
        address owner,
        address paymentERC20,
        address payableERC20,
        uint256 amount_each_target,
        uint256 contribution_fee,
        uint256 trading_fee,
        uint256 withdrawal_fee,
        uint256 transfer_funds_fee,
        uint256 migrate_wallet_fee,
        uint256 monthly_fee
    );

    function transferFrom(address tokenAddress, address from, address to, uint256 amount) external;
    function isMigrateAllowed(address wallet) external view returns (bool);
}
