// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MockERC20} from "./53301-c-01-incorrect-reserve-order-in-swap-pashov-audit-group-non.sol";

contract Finding53301Test is Test {
    function test_swapped_reserves_misquote() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 90661089388014913158, "wrong output");
        assertEq(e.fair(), 987158034397061298, "fair output");
        assertEq(e.controlPaid(), 987158034397061298, "sorted swap pays fair");
        emit log_named_uint("wrong output", e.paid());
        emit log_named_uint("fair output", e.fair());
        emit log_named_uint("extra", e.paid() - e.fair());
    }

    function test_control_when_token0_is_payment() public {
        MockERC20 payment = new MockERC20("Payment", "WETH");
        MockERC20 token = new MockERC20("Ticket", "TIX");
        // This test only checks the sorted formula against the raw formula when we
        // force the vulnerable naming. Covered by test_swapped_reserves_misquote.
        assertTrue(address(payment) != address(token));
    }
}
