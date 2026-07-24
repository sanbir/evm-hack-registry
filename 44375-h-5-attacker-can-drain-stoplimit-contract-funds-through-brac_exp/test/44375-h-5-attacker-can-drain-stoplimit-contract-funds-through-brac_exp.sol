// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44375-h-5-attacker-can-drain-stoplimit-contract-funds-through-brac.sol";
contract PoC_44375 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
