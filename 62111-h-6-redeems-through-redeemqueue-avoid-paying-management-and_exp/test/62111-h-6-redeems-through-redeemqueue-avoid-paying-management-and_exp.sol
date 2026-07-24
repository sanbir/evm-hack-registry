// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62111-h-6-redeems-through-redeemqueue-avoid-paying-management-and.sol";
contract PoC_62111 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
