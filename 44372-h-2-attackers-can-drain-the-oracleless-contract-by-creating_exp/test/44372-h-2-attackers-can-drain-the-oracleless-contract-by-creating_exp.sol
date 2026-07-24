// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44372-h-2-attackers-can-drain-the-oracleless-contract-by-creating.sol";
contract PoC_44372 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
