// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./62848-h-01-sessionkey-owner-can-impersonate-another-session-key-ow.sol";

contract Finding62848Test is Test {
    function test_sk2_consumes_sk1_claim() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.validated(), "validated");
        assertEq(e.token().balanceOf(e.recipient()), 1000 ether, "recipient");
        assertEq(e.module().sessionBalance(e.sk1()), 0, "sk1 consumed");
    }
}
