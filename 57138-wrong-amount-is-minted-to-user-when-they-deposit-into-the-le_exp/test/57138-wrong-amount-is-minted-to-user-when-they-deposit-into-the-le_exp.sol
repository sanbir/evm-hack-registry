// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, RTokenFixed} from "./57138-wrong-amount-is-minted-to-user-when-they-deposit-into-the-le.sol";

contract Finding57138Test is Test {
    function test_exploit_unscaled_mint_withdraws_1100_for_a_1000_deposit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.withdrawn(), 1100 ether, "paid 1100");
        assertEq(e.token().balanceOf(address(e)), 1100 ether, "attacker up 100");
        assertEq(e.token().balanceOf(address(e.rtoken())), 900 ether, "900 left of alice's 1000");
        assertEq(e.rtoken().balanceOf(address(e.victim())), 1000 ether, "alice shares still 1000");
        assertEq(e.rtoken().preview(address(e.victim())), 1100 ether, "alice is quoted 1100");
    }

    function test_control_scaled_mint_returns_the_deposit() public {
        Token token = new Token();
        RTokenFixed rt = new RTokenFixed(token);
        token.mint(address(this), 1000 ether);
        rt.accrueTo(11 * 10 ** 26);
        token.approve(address(rt), 1000 ether);
        rt.deposit(1000 ether);
        uint256 got = rt.withdraw();

        assertEq(got, 1000 ether - 1, "deposit comes back, rounding dust only");
        assertLt(got, 1100 ether, "not the unscaled payout");
        assertEq(token.balanceOf(address(rt)), 1, "one wei of rounding left");
    }
}
