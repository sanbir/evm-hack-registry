// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44006-h-02-the-usdt-reward-claiming-functionality-of-vestedstaking.sol";
contract PoC_44006 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
