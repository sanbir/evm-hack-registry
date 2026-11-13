// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./26461-c-02-operator-can-still-claim-rewards-after-being-removed-fr.sol";

contract FindingTest is Test {
    function test_claim_after_removal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.accrued(), e.N(), "accrued");
        assertFalse(e.stillOperator(), "removed");
        assertEq(e.rewardsLeftOnBooks(), e.N(), "left");
        assertEq(e.claimed(), e.N(), "claimed");
        assertEq(e.rewards().balanceOf(address(e)), e.N(), "attacker");
        assertEq(e.controlSeized(), e.N(), "seized");
        assertEq(e.controlClaimed(), 0, "control claim");
        assertEq(e.poolGot(), e.N(), "pool");
        assertEq(e.rewardsC().balanceOf(address(e)), 0, "control attacker");
        console2.log("accrued");
        console2.log(e.accrued());
        console2.log("still on books after removal");
        console2.log(e.rewardsLeftOnBooks());
        console2.log("claimed");
        console2.log(e.claimed());
        console2.log("control seized to pool");
        console2.log(e.controlSeized());
        console2.log("control claim");
        console2.log(e.controlClaimed());
    }
}
