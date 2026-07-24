// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./31192-h-3-reentrancy-in-vestingsolclaim-will-allow-users-to-drain.sol";
contract PoC_31192 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
