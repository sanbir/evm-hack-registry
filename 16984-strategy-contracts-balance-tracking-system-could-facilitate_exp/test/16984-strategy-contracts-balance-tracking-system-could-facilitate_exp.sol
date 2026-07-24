// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16984-strategy-contracts-balance-tracking-system-could-facilitate.sol";
contract PoC_16984 is Test { function test_exploit() public { new Exploit().run(); } }
