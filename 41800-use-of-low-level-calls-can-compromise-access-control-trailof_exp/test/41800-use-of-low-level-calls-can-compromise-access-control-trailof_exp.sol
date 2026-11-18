// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, Accounting} from "./41800-use-of-low-level-calls-can-compromise-access-control-trailof.sol";

contract Finding41800Test is Test {
    function test_exploit_callback_pays_victim_bond_to_attacker() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "stolen");
        assertEq(e.accounting().bonded(e.VICTIM()), 0, "bond cleared");
        assertEq(e.token().balanceOf(address(e.accounting())), 0, "accounting empty");
    }

    function test_control_direct_pay_reverts_and_fixed_callback_keeps_bond() public {
        Exploit e = new Exploit();
        Accounting accounting = e.accounting();
        address victim = e.VICTIM();
        vm.expectRevert(bytes("onlyAllowedModule"));
        accounting.pay(victim, address(this), 1 ether);
        e.oracle().finalizeFixed(address(e.notifier()));
        assertEq(accounting.bonded(e.VICTIM()), 1000 ether, "bond intact");
        assertEq(e.token().balanceOf(address(accounting)), 1000 ether, "tokens intact");
    }
}
