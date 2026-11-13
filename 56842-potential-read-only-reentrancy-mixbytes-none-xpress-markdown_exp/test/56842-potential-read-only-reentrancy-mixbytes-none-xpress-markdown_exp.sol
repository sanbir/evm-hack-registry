// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Mini, LOBFixed, Lender, Trader} from "./56842-potential-read-only-reentrancy-mixbytes-none-xpress-markdown.sol";

contract Finding56842Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_borrows_against_stale_balance() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.bookAfter(), 1_000 ether, "book showed 1000 before the withdraw");
        assertEq(e.staleSeen(), 1_000 ether, "view still returned 1000 inside the callback");
        assertEq(e.borrowed(), 1_000 ether, "lender paid 1000 against the stale view");
        assertEq(e.lenderLeft(), 0, "lender liquidity gone");
        assertEq(e.attackerGot(), 1_000 ether, "attacker kept the extra 1000");
        assertEq(Mini(address(e.token())).balanceOf(ATTACKER), 1_000 ether, "EOA profit");
    }

    function test_control_updates_balance_before_transfer() public {
        Mini token = new Mini();
        LOBFixed lob = new LOBFixed(token);
        Lender lender = new Lender(token, lob);
        Trader trader = new Trader();
        token.mint(address(trader), 1_000 ether);
        token.mint(address(lender), 1_000 ether);
        trader.arm(lob, lender, token);
        trader.poke();

        assertEq(trader.stale(), 0, "view is already zero in the callback");
        assertEq(trader.borrowed(), 0, "lender did not pay");
        assertEq(token.balanceOf(address(lender)), 1_000 ether, "lender keeps 1000");
        assertEq(token.balanceOf(ATTACKER), 0, "no extra tokens");
        assertEq(token.balanceOf(address(trader)), 1_000 ether, "trader only has the honest withdraw");
    }
}
