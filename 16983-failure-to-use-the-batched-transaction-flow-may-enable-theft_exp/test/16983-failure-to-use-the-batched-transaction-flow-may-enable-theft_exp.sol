// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16983-failure-to-use-the-batched-transaction-flow-may-enable-theft.sol";
contract PoC_16983 is Test { function test_exploit() public { new Exploit().run(); } }
