// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64067-h-01-recipient-bytes-silent-burn-non-20-byte.sol";

contract PoC_64067 is Test {
    function test_malformed_recipient_burns_source_tokens() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.unrecoverable());
        assertEq(exploit.lost(), 100);
    }
}
