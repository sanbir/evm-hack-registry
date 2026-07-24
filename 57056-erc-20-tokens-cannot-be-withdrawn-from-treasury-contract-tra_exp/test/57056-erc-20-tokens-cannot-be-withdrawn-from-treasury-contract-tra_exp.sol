// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./57056-erc-20-tokens-cannot-be-withdrawn-from-treasury-contract-tra.sol";
contract PoC_57056 is Test { function test_exploit() public { new Exploit().run(); } }
