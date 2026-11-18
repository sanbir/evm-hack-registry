// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, FeeToken, DefaultDepositContract, Bob} from "./17856-token-management-diculties-caused-by-the-addition-of-arbitra.sol";

contract Finding17856Test is Test {
    function test_exploit_overcredit_lets_alice_strand_bob() public {
        Exploit e = new Exploit();
        e.run();
        assertFalse(e.bobPaid());
        assertEq(e.token().balanceOf(address(e.exchange())), 800 ether, "short 200");
        assertEq(e.exchange().credits(address(e.bob()), address(e.token())), 1000 ether);
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "alice even");
    }

    function test_control_check_balance_credits_only_what_arrived() public {
        FeeToken token = new FeeToken();
        DefaultDepositContract ex = new DefaultDepositContract(address(this));
        ex.registerToken(address(token));
        ex.setCheckBalance(address(token), true);
        Bob bob = new Bob();
        token.mint(address(bob), 1000 ether);
        bob.deposit(ex, token, 1000 ether);
        assertEq(ex.credits(address(bob), address(token)), 900 ether, "net of 10%");
        assertEq(token.balanceOf(address(ex)), 900 ether, "matches");
    }
}
