// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./35121-h-8-malicious-users-can-steal-reward-tokens-via-re-entrancy.sol";
contract PoC_35121 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
