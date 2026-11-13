// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit} from "./30496-dos-of-an-account-using-frontrun-mixbytes-none-kinto-markdow.sol";

contract Finding30496Test is Test {
    function test_frontrun_leaves_1000_stuck() public {
        Exploit e = new Exploit();
        e.run();

        console2.log("wallet", e.walletAddr());
        console2.log("timestamp", e.timestamp());
        console2.log("withdrew", e.withdrew());
        console2.log("stuck", e.stuck());

        assertEq(e.timestamp(), 0, "walletTs");
        assertFalse(e.withdrew(), "later call");
        assertEq(e.stuck(), 1_000 ether, "stuck");
        assertEq(e.token().balanceOf(e.walletAddr()), 1_000 ether, "balance");
    }

    function test_control_create_account_then_withdraw() public {
        Exploit e = new Exploit();
        e.runControl();

        console2.log("control withdrew", e.controlWithdrew());
        console2.log("control balance", e.controlBalance());

        assertTrue(e.controlWithdrew(), "call");
        assertEq(e.controlBalance(), 1_000 ether, "paid");
    }
}
