// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, HydroTokenFixed} from "./35502-anyone-could-remove-anyone-from-the-blacklist-zokyo-none-hyd.sol";

contract Finding35502Test is Test {
    function test_exploit_unlists_and_moves_the_frozen_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.listedBefore(), "started blacklisted");
        assertTrue(e.listedAfter() == false, "blacklist entry was removed");
        assertEq(e.moved(), e.FROZEN(), "1000 tokens moved");
        assertEq(e.token().balanceOf(e.RECEIVER()), 1000 ether, "receiver holds them");
    }

    function test_control_only_the_owner_can_remove() public {
        HydroTokenFixed token = new HydroTokenFixed();
        token.mint(address(0x3333), 1000 ether);
        token.blacklist(address(0x3333));
        address[] memory listed = new address[](1);
        listed[0] = address(0x3333);
        vm.prank(address(0x4444));
        vm.expectRevert(bytes("owner"));
        token.removeAddrFromBlacklist(listed, address(0x3333));
        assertTrue(token.denylist(address(0x3333)), "still listed");
    }
}
