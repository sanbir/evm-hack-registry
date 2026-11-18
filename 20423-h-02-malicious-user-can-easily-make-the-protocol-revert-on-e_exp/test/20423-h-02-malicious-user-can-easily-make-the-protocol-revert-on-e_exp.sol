// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usdt, Router, AdapterFixed} from "./20423-h-02-malicious-user-can-easily-make-the-protocol-revert-on-e.sol";

contract Finding20423Test is Test {
    function test_exploit_second_usdt_swap_reverts() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.secondReverted(), "second swap reverted");
        assertEq(e.usdt().allowance(address(e.adapter()), address(e.router())), 1, "1 wei allowance");
        assertEq(e.usdt().balanceOf(address(e.victim())), 1000 ether, "victim still holds 1000");
    }

    function test_control_amount_in_approval_allows_the_second_swap() public {
        Usdt usdt = new Usdt();
        Router router = new Router(usdt);
        AdapterFixed adapter = new AdapterFixed(usdt, router);
        usdt.mint(address(this), 1);
        usdt.transfer(address(adapter), 1);
        usdt.mint(address(this), 1 ether);
        usdt.approve(address(adapter), 1 ether);
        adapter.swapExactInputSingle(1 ether);
        assertEq(usdt.allowance(address(adapter), address(router)), 0, "allowance back to 0");
        usdt.mint(address(this), 1000 ether);
        usdt.approve(address(adapter), 1000 ether);
        adapter.swapExactInputSingle(1000 ether);
        assertEq(usdt.balanceOf(address(router)), 1001 ether, "both swaps pulled");
    }
}
