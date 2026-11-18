// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MiniToken, ClaggBaseAdapterFixed} from
    "./46277-claggbaseadapter-handlefee-incorrectly-calculates-the-user-s.sol";

contract Finding46277Test is Test {
    function test_exploit_second_withdraw_reverts_and_locks_10() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.secondReverted(), "reverted");
        assertEq(e.stuck(), 10 ether, "stuck");
        assertEq(e.userBalance(), 109 ether, "user");
    }

    function test_control_entire_remainder_is_profit() public {
        MiniToken token = new MiniToken();
        address sink = address(0xFEE);
        ClaggBaseAdapterFixed adapter = new ClaggBaseAdapterFixed(token, sink);
        token.mint(address(this), 100 ether);
        token.approve(address(adapter), 100 ether);
        adapter.deposit(100 ether);
        token.mint(address(adapter), 20 ether);
        adapter.withdraw(110 ether);
        adapter.withdraw(10 ether);

        assertEq(token.balanceOf(address(adapter)), 0, "adapter empty");
        assertEq(token.balanceOf(address(this)), 118 ether, "user received remainder");
        assertEq(token.balanceOf(sink), 2 ether, "fees on 10 then 10");
    }
}
