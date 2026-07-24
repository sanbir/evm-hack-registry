// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./28949-h-2-vault-leverage-can-be-increased-to-any-value-up-to-min-m.sol";
contract PoC_28949 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
