// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./26042-h-08-due-to-inadequate-checks-an-adversary-can-call-branchbr.sol";

contract MaiaRetrieveDepositPoisonTest is Test {
    Exploit exp;

    function setUp() public {
        exp = new Exploit();
    }

    function test_poison_nonce_locks_user_deposit() public {
        exp.run();
        emit log_named_uint("branch locked DEP", exp.branchLocked());
        assertTrue(exp.noncePoisoned(), "nonce poisoned");
        assertTrue(exp.rootRejected(), "root rejected");
        assertEq(exp.branchLocked(), 1000 ether, "1000 DEP locked");
    }
}
