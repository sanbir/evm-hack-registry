// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./53316-c-05-the-users-are-not-able-to-redeem-their-funds-pashov-aud.sol";

contract Finding53316Test is Test {
    function test_agent_zero_blocks_redeem() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.redeemReverted(), "redeem reverted");
        assertEq(e.stuck(), 1000 ether, "1000 stays");
        assertEq(e.controlPaid(), 1000 ether, "control pays 1000");
        assertEq(e.asset().balanceOf(address(e.vault())), 1000 ether, "vault still holds 1000");
        emit log_named_uint("stuck", e.stuck());
        emit log_named_uint("control paid", e.controlPaid());
    }
}
