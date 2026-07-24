// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./63046-h-2-caller-supplied-controltower-lets-anyone-be-the-migrator.sol";
contract PoC_63046 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
