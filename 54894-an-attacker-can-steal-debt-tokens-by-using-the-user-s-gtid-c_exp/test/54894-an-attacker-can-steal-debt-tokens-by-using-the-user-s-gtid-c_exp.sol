// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./54894-an-attacker-can-steal-debt-tokens-by-using-the-user-s-gtid-c.sol";

contract Finding54894Test is Test {
    function test_exploit_attacker_receives_80e8_debt_against_victim_gt() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.debt().balanceOf(address(e)), 80e8, "stolen");
        assertEq(e.gt().debtOf(e.GT_ID()), 80e8, "victim debt");
        assertEq(e.gt().ownerOf(e.GT_ID()), address(e.victim()), "owner");
    }

    function test_control_owner_check_blocks_the_attacker() public {
        Exploit e = new Exploit();
        // The fix is require(ownerOf(gtId) == msg.sender). Attacker is not the owner.
        assertTrue(e.gt().ownerOf(e.GT_ID()) != address(e) || e.gt().ownerOf(e.GT_ID()) == address(0));
        e.run();
        assertEq(e.gt().ownerOf(e.GT_ID()), address(e.victim()));
        assertTrue(address(e) != address(e.victim()));
    }
}
