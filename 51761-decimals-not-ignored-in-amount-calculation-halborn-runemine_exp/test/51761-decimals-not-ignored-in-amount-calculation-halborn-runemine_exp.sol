// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./51761-decimals-not-ignored-in-amount-calculation-halborn-runemine.sol";

contract Finding51761Test is Test {
    function test_raw_amount_ignores_destination_decimals() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.buggyOut(), 99_000_000, "out");
        assertEq(e.controlOut(), 990_000, "control");
        assertEq(e.excess(), 98_010_000, "excess");

        console2.log("buggy payout");
        console2.log(e.buggyOut());
        console2.log("control payout");
        console2.log(e.controlOut());
        console2.log("excess");
        console2.log(e.excess());
    }
}
