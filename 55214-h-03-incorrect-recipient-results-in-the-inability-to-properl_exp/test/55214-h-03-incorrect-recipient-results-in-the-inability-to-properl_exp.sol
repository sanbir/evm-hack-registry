// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./55214-h-03-incorrect-recipient-results-in-the-inability-to-properl.sol";

contract Finding55214Test is Test {
    function test_wrong_recipient_blocks_redeem() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.userShares(), 1000 ether, "user holds the island shares");
        assertTrue(e.redeemReverted(), "burve redeem reverted");
        assertEq(e.stuck(), 1000 ether, "1000 stuck in the island");
        assertEq(e.controlPaid(), 1000 ether, "control paid 1000");
        assertEq(e.underlying().balanceOf(address(e.island())), 1000 ether, "vuln island still holds 1000");
        emit log_named_uint("stuck", e.stuck());
        emit log_named_uint("control paid", e.controlPaid());
    }
}
