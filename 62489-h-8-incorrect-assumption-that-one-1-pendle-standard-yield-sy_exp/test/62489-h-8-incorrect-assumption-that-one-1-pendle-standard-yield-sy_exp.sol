// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62489-h-8-incorrect-assumption-that-one-1-pendle-standard-yield-sy.sol";
contract PoC_62489 is Test {
    function test_exploit() public { Exploit e = new Exploit(); e.run(); }
}
