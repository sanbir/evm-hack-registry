// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18260-transfer-operations-may-silently-fail-due-to-the-lack-of-con.sol";
contract PoC_18260 is Test { function test_exploit() public { new Exploit().run(); } }
