// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; import "forge-std/Test.sol"; import "./51370-broken-stargate-deposit-flow-due-to-missing-allowance-halbor.sol"; contract Test51370 is Test{function test_exploit() public{Exploit e=new Exploit();e.run();assertTrue(e.depositBlocked());assertEq(e.lp().balanceOf(address(e.chef())),100);}}
