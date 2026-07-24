// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./18213-ousd-allows-users-to-transfer-more-tokens-than-expected-trai.sol";
contract PoC_18213 is Test { function test_exploit() public { new Exploit().run(); } }
