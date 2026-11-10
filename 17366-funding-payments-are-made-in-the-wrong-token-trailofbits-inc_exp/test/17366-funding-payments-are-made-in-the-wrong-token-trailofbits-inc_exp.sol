// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from
    "./17366-funding-payments-are-made-in-the-wrong-token-trailofbits-inc.sol";

contract Finding17366Test is Test {
    function test_exploit_pays_vbase_instead_of_1000_ua() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.vBase().balanceOf(e.ALICE()), 0.05 ether, "Alice received 0.05 vBase");
        assertEq(e.ua().balanceOf(e.ALICE()), 0, "Alice received 0 UA");
        assertEq(e.UA_OWED(), 1000 ether, "owed 1000 UA");
        assertEq(uint256(e.vault().owedUa(int256(0.05 ether))), 1000 ether, "index conversion");

        console2.log("vBase paid", e.vBase().balanceOf(e.ALICE()));
        console2.log("UA paid", e.ua().balanceOf(e.ALICE()));
        console2.log("UA owed", e.UA_OWED());
    }

    function test_control_pays_1000_ua() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.ua().balanceOf(c.ALICE()), 1000 ether, "Alice received 1000 UA");
        assertEq(c.vBase().balanceOf(c.ALICE()), 0, "no vBase");

        console2.log("control UA", c.ua().balanceOf(c.ALICE()));
        console2.log("control vBase", c.vBase().balanceOf(c.ALICE()));
    }
}
