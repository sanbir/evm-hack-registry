// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16739-aztec-confidentialapprove-replay-status.sol";

contract PoC_16739 is Test {
    function test_confidential_approval_signature_replays_with_status_flip() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertTrue(exploit.revoked());
        assertTrue(exploit.replayed());
        assertTrue(exploit.registry().approved(exploit.noteOwner(), exploit.spender()));
    }
}
