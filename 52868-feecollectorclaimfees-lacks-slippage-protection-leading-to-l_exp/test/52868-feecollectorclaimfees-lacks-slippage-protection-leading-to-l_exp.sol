// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./52868-feecollectorclaimfees-lacks-slippage-protection-leading-to-l.sol";

contract Finding52868Test is Test {
    function test_claim_pays_full_payout_for_one_wei_of_fees() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimFees(), 1, "dust");
        assertEq(e.victimPayoutLeft(), 0, "paid");
        assertTrue(e.controlReverted(), "control");
        assertEq(e.controlPayoutLeft(), e.PAYOUT(), "kept");
        assertEq(e.lost(), e.PAYOUT(), "lost");

        console2.log("victim fee received");
        console2.log(e.victimFees());
        console2.log("victim payout left");
        console2.log(e.victimPayoutLeft());
        console2.log("control payout kept");
        console2.log(e.controlPayoutLeft());
    }
}
