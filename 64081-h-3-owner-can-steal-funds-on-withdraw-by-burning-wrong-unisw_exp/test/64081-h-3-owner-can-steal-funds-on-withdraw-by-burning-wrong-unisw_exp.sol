// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64081-h-3-owner-can-steal-funds-on-withdraw-by-burning-wrong-unisw.sol";
contract PoC_64081 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
