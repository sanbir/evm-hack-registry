// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48951-h-12-dos-of-market-operations-with-malicious-offers-code4ren.sol";

contract PoC_48951 is Test {
    function test_dosZeroRecipientOffer() public {
        Exploit e = new Exploit();
        e.run();
    }
}
