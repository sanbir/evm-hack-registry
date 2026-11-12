// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./50037-h-01-executecallback-call-causes-that-ownership-cannot-be-up.sol";

contract OwnershipCallbackTest is Test {
    uint256 internal constant AMOUNT = 1000 ether;

    function test_exploit_oldOwnerStillMovesTheBalance() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.updateBlocked(), "blocked");
        assertEq(e.ownerAfter(), address(e), "old owner");
        assertEq(e.oldOwnerPulled(), AMOUNT, "pulled");
        assertTrue(e.oldOwnerBlockedOnControl(), "control blocked");
        assertEq(e.newOwnerGot(), AMOUNT, "new owner");
        assertEq(e.token().balanceOf(address(e)), AMOUNT, "exploit");
        assertEq(e.token().balanceOf(address(e.newOwner())), AMOUNT, "new");
        assertEq(address(e.controlNft().owner()), address(e.newOwner()), "owner");
    }

    function test_control_updateCompletesAndOldOwnerCannotPull() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.newOwnerGot(), AMOUNT, "completed transfer");
        assertTrue(e.oldOwnerBlockedOnControl(), "old owner");
    }
}
