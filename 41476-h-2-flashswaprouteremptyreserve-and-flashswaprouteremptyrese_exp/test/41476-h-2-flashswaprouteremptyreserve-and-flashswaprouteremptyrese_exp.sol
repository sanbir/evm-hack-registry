// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./41476-h-2-flashswaprouteremptyreserve-and-flashswaprouteremptyrese.sol";

contract Finding41476Test is Test {
    function test_exploit_last_redeem_reverts_and_locks_ra() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.redeemReverted(), "reverted");
        assertEq(e.ra().balanceOf(address(e.vault())), 10 ether, "locked");
        assertEq(e.ra().balanceOf(address(e)), 0, "user");
    }

    function test_control_returning_the_emptied_amount_pays_ra() public {
        Exploit e = new Exploit();
        e.runFixed();
        assertEq(e.ra().balanceOf(address(e)), 10 ether, "returned");
        assertEq(e.ra().balanceOf(address(e.vault())), 0, "empty");
    }
}
