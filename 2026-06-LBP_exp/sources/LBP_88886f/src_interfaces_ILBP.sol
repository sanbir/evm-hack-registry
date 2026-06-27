// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ILBP
 * @notice LBP interface with raw balance access for protocol-internal callers.
 *
 * Balance semantics (v8): LBP overrides ERC20 `balanceOf` to return
 * `raw + hashrate.pendingRewards(account)` for non-system addresses (virtual
 * credit). Wallets / DEX UIs see "spendable balance = perceived balance"
 * without needing to simulate `claim()` off-chain. Send-Max / Sell-Max work
 * because LBP._update Layer 8 calls `notifyHarvest(from)` BEFORE Layer 10
 * super._update, materializing pending into raw before the balance check.
 *
 *   - balanceOf(user):     OZ ERC20 + virtual credit. Wallets / DEX / collateral.
 *   - rawBalanceOf(user):  underlying `_balances[user]` only. Used by protocol-
 *                          internal callers (vault reserve reads, FomoVault.pool,
 *                          tests measuring realized mint deltas) that need the
 *                          unmodified value.
 *
 * @dev System addresses (this / pair / DEAD / 4 vaults / hashrate) bypass the
 *      virtual credit and return raw — they don't accumulate hashrate-derived
 *      pending and the cross-call would always return 0.
 */
interface ILBP is IERC20 {
    /**
     * @notice Returns the underlying `_balances[account]` without the virtual-
     *         credit `pendingRewards` adjustment that `balanceOf` adds.
     * @param account Address to query.
     * @return The raw underlying balance.
     */
    function rawBalanceOf(address account) external view returns (uint256);
}
