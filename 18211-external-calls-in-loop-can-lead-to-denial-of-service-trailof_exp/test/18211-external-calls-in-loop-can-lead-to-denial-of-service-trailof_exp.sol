// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18211-external-calls-in-loop-can-lead-to-denial-of-service-trailof.sol";
contract PoC_18211 is Test { function test_exploit() public { new Exploit().run(); } }
