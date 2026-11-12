// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Bronze,
    DragmaFixed,
    Exploit
} from "./61818-h-01-hero-owner-can-never-receive-bronze-tier-gacha-tokens-s.sol";

contract Finding61818Test is Test {
    function test_exploit_bronze_claim_is_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.claimed(), 0, "claim id");
        assertEq(e.owed(), 1, "owed N");
        assertEq(e.items().balanceOf(e.hero()), 0, "hero balance");
        emit log_named_uint("bronze owed", e.owed());
        emit log_named_uint("bronze paid", e.items().balanceOf(e.hero()));
    }

    function test_control_pays_one_bronze() public {
        Bronze items = new Bronze();
        DragmaFixed fixedDragma = new DragmaFixed(items);
        address hero = address(0xB0B);
        fixedDragma.setHero(1, hero, 0, 6);
        uint256 id = fixedDragma.claimBonus(1, 0, 0);
        assertEq(id, 1, "bronze id");
        assertEq(items.balanceOf(hero), 1, "control paid N");
    }
}
