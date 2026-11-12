// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./50017-h-01-executetransactionfromoutside-does-not-increment-the-no.sol";

contract NonceReplayTest is Test {
    uint256 internal constant AMOUNT = 1000 ether;
    function test_exploit_sameSignaturePaysTwice() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.firstPay(), AMOUNT, "first");
        assertEq(e.replayed(), AMOUNT * 2, "replay");
        assertEq(e.nonceAfter(), 0, "nonce");
        assertTrue(e.controlReplayBlocked(), "blocked");
        assertEq(e.controlPaid(), AMOUNT, "control");
        assertEq(e.control().nonce(), 1, "control nonce");
        assertEq(e.token().balanceOf(e.PAYEE()), AMOUNT * 2, "payee");
    }

    function test_control_incrementedNonceRejectsTheSecondSignature() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.controlPaid(), AMOUNT, "one payment");
        assertEq(e.token().balanceOf(e.CONTROL_PAYEE()), AMOUNT, "control payee");
        assertEq(e.token().balanceOf(address(e.control())), AMOUNT, "unspent second 1000");
    }
}
