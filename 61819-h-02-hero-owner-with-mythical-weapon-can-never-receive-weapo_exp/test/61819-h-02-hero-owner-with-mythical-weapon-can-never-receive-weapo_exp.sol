// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    DragmaFixed,
    Exploit,
    Shard
} from "./61819-h-02-hero-owner-with-mythical-weapon-can-never-receive-weapo.sol";

contract Finding61819Test is Test {
    function test_exploit_mythical_hero_is_paid_zero() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.claimed(), 0, "mythical claim is 0");
        assertEq(e.owed(), 2, "N shards are owed");
        assertEq(e.items().balanceOf(address(this)), 0, "caller holds nothing");
        assertEq(e.legendaryPaid(), 2, "rarity 5 still pays N");
        assertEq(e.items().balanceOf(e.LEGENDARY_HERO()), 2, "legendary holder received N");
    }

    function test_control_pays_the_mythical_hero() public {
        Shard items = new Shard();
        DragmaFixed fixedDragma = new DragmaFixed(items);
        fixedDragma.setHero(1, address(this), 6, 3);
        (, uint256 minted) = fixedDragma.claimBonus(1, 0, 0);

        assertEq(minted, 2, "control pays N");
        assertEq(items.balanceOf(address(this)), 2, "mythical hero receives N");
    }
}
