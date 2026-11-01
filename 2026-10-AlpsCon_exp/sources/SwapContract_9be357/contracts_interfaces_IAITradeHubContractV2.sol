// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface IAITradeHubContractV2 {
    function getStats(address wallet) external view returns  (
        uint num_contributors,
        uint256 total_pending_amount,
        uint256 total_locked_amount,
        uint256 last_distribute_profit,
        uint256 user_locked_amount,
        uint256 user_pending_amount,
        uint256 user_debt_amount,
        uint256 user_paid_amount,
        uint256 user_balance,
        uint256 user_claimable_profit,
        uint256 user_current_service_fee,
        bool user_is_re_compound
    );

    function getConfig() external view returns (
        address owner,
        address paymentERC20,
        address payableERC20,
        uint256 amount_each_target,
        uint256 contribution_fee,
        uint256 trading_fee,
        uint256 withdrawal_fee,
        uint256 monthly_fee
    );
}
