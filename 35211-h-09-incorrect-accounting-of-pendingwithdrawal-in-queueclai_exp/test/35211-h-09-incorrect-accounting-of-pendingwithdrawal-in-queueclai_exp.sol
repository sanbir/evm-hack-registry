// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./35211-h-09-incorrect-accounting-of-pendingwithdrawal-in-queueclai.sol";

/*//////////////////////////////////////////////////////////////////////////
    Gondi [H-09] — pendingWithdrawal assignment overwrites prior queues.

    Re-asserts: queue 2 should have 100e18, only has 50e18 → lost 50e18.
//////////////////////////////////////////////////////////////////////////*/
contract PendingWithdrawalOverwriteTest is Test {
    function test_queueClaim_overwrites_prior_pendingWithdrawal() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.actualQ2(), 50e18, "only last contribution kept");
        assertEq(exp.expectedQ2(), 100e18, "two contributions expected");
        assertEq(exp.lost(), 50e18, "50e18 erased");
    }
}
