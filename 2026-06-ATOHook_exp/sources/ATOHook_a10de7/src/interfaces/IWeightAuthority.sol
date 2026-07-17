// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title  IWeightAuthority — the staking weight surface the LP manager reports into (mining-spec §4)
/// @notice Tiers 2/3 (the LP manager) credit/debit tier-agnostic deposit-basis curve-weight against the
///         SAME unified reward ledger that tier-1 custodial staking uses. Post-merge that ledger lives on
///         the ATOHook (the streamer was folded in), so the hook implements this. The hook gates both
///         calls to the single, deployer-wired `lpManager` and enforces the shared 6-block hold.
interface IWeightAuthority {
    function addWeight(address user, uint256 basis) external; // onlyLPManager; arms the hold for `user`
    function removeWeight(address user, uint256 basis) external; // onlyLPManager; enforces the hold

    /// @notice Atomically move `amount` of `user`'s tier-1 custodial stake to `to` (the LP manager), for the
    ///         one-tx "staked ATO → LP" path (§5.3). onlyLPManager. No source-hold check: the manager re-adds
    ///         weight via `addWeight` in the SAME tx (fresh 6-block hold), so there is no reward gap to JIT.
    function unstakeFor(address user, uint256 amount, address to) external;

    /// @notice Re-stake `amount` ATO into `user`'s tier-1 custodial stake, pulled from the caller (the LP
    ///         manager) via transferFrom. onlyLPManager. Counterpart to `unstakeFor`: `depositFromStake` uses
    ///         it to return the UNUSED slice of stake-sourced ATO to stake (keeping the 6-block hold) instead
    ///         of the wallet. The manager passes `msg.sender` as `user` (restake only your own).
    function stakeFor(address user, uint256 amount) external;
}
