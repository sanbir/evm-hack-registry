// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./28948-h-1-liquidator-can-liquidate-user-while-increasing-user-posi.sol";
contract PoC_28948 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
