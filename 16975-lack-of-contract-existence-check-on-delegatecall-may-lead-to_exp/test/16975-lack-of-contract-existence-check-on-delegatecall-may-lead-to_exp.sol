// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16975-lack-of-contract-existence-check-on-delegatecall-may-lead-to.sol";
contract PoC_16975 is Test { function test_exploit() public { new Exploit().run(); } }
