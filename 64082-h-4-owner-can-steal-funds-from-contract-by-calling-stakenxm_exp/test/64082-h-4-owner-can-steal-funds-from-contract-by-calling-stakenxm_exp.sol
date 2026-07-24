// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64082-h-4-owner-can-steal-funds-from-contract-by-calling-stakenxm.sol";
contract PoC_64082 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
