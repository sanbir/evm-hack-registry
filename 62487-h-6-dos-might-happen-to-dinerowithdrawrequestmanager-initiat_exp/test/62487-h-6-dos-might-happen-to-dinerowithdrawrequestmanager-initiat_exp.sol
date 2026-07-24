// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62487-h-6-dos-might-happen-to-dinerowithdrawrequestmanager-initiat.sol";
contract PoC_62487 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
