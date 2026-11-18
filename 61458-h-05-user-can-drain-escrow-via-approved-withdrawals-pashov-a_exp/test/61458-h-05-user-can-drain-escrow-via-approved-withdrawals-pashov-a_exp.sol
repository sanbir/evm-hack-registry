// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./61458-h-05-user-can-drain-escrow-via-approved-withdrawals-pashov-a.sol";

contract Finding61458Test is Test {
    function test_exploit_burns_owner_shares_and_locks_escrow() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.a1Cash(), 800 ether, "a1");
        assertEq(e.a2Shares(), 0, "shares");
        assertEq(e.a2RequestAssets(), 400 ether, "request");
        assertTrue(e.ownerWithdrawReverted(), "a2");
        assertTrue(e.innocentReverted(), "innocent");
        assertEq(e.depositLeft(), 400 ether, "locked");
        assertEq(e.usdc().balanceOf(address(e.innocent())), 0, "paid");
    }
}
