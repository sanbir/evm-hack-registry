// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61409-c-07-resource-lock-validator-signature-proof-replay.sol";

contract PoC_61409 is Test {
    function test_signature_proof_replays_with_new_nonce() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.replayed());
        assertEq(exploit.wallet().executions(), 2);
        assertEq(exploit.validator().validations(), 2);
    }
}
