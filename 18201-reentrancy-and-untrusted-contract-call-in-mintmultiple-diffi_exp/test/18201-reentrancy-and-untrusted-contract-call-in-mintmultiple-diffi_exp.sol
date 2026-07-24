// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18201-reentrancy-and-untrusted-contract-call-in-mintmultiple-diffi.sol";
contract PoC_18201 is Test { function test_exploit() public { new Exploit().run(); } }
