// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./16976-use-of-delegatecall-in-a-payable-function-inside-a-loop-trai.sol";
contract PoC_16976 is Test { function test_exploit() public { vm.deal(address(this), 1 ether); new Exploit().run{value: 1 ether}(); } }
