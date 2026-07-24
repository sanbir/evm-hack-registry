// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62848-h-01-sessionkey-owner-impersonate-session-key-owner.sol";

contract PoC_62848 is Test {
    function test_session_key_can_consume_sibling_session() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.impersonated());
        assertTrue(exploit.module().claimed(exploit.SESSION_ONE()));
        assertFalse(exploit.module().claimed(exploit.SESSION_TWO()));
    }
}
