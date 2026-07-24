// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62491-h-10-malicious-user-can-change-the-tradetype-to-steal-funds.sol";
contract PoC_62491 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
