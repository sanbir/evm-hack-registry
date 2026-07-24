// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./58397-h-28-subsequent-crosschain-borrows-dont-accrue-interest-on-e.sol";
contract PoC_58397 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
