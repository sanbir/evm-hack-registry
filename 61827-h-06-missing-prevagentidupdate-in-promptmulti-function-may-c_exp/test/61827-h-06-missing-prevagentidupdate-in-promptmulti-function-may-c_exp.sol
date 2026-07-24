// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61827-h-06-missing-prevagentidupdate-in-promptmulti-function-may-c.sol";
contract Virtuals61827Test is Test { function test_promptMultiBurnsAndMisdirectsPayments() public { Exploit e=new Exploit();e.run();assertEq(e.burned(),10);assertEq(e.misdirected(),50);assertEq(e.token().balanceOf(address(e.vault0())),0); } }
