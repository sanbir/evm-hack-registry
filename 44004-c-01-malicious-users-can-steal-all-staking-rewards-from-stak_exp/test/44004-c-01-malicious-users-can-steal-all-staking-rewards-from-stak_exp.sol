// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./44004-c-01-malicious-users-can-steal-all-staking-rewards-from-stak.sol";
contract PoC_44004 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
