// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18214-ousd-total-supply-can-be-arbitrary-even-smaller-than-user-ba.sol";
contract PoC_18214 is Test { function test_exploit() public { new Exploit().run(); } }
