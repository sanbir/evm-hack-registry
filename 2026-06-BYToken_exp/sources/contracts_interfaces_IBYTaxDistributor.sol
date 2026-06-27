// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBYTaxDistributor
 * @notice BY/BYC 卖出盈利税分发接口。
 * @dev Token 合约把盈利税资金交给分发器，由分发器按节点、推荐人、21 代、社区等规则处理。
 */
interface IBYTaxDistributor {
    /// @notice 直接用 BNB 分发卖出盈利税。
    function distributeTax(
        address token,
        uint256 bnbAmount,
        address seller
    ) external payable;

    /// @notice 查询用户待领取的卖出盈利税推荐奖励。
    function pendingTaxReward(address user) external view returns (uint256);

    /// @notice 用户主动领取卖出盈利税推荐奖励。
    function claimTaxReward() external;
}
