// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65096-h-09-cross-msg-recipient-can-block-checkpoint-submission-cod.sol";

contract PoC_65096_h_09_cross_msg_recipient_can_block_checkpoint_submission_cod is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // fund Exploit for findings that need ETH
        vm.deal(address(e), 100 ether);
        e.run();
    }
}
