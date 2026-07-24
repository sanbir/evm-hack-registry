// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol"; import "./29738-a-user-can-steal-an-already-transfered-and-bridged-resdl-loc.sol";
contract StakeLinkApprovalTest is Test {function test_staleApprovalStealsReturnedLock() external {Exploit e=new Exploit();e.run();assertEq(e.pool().ownerOf(2),address(e));}}
