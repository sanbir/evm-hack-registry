// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./48378-improper-settlement-calculation-ottersec-none-vertex-protoco.sol";

contract Finding48378Test is Test {
    function test_settlement_pays_the_whole_pool() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 200e18, "paid 200");
        assertEq(e.fair(), 20e18, "fair 20");
        assertEq(e.extra(), 180e18, "extra 180");
        assertEq(e.controlPaid(), 20e18, "control pays the share");
        assertEq(e.quoteToken().balanceOf(address(e)), 220e18, "200 vuln + 20 control");
        emit log_named_uint("paid", e.paid());
        emit log_named_uint("fair", e.fair());
        emit log_named_uint("extra", e.extra());
    }
}
