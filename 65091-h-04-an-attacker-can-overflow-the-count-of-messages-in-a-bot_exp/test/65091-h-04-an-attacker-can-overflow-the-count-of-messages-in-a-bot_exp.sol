// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./65091-h-04-an-attacker-can-overflow-the-count-of-messages-in-a-bot.sol";

contract PoC_65091_h_04_an_attacker_can_overflow_the_count_of_messages_in_a_bot is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        // fund Exploit for findings that need ETH
        vm.deal(address(e), 100 ether);
        e.run();
    }
}
