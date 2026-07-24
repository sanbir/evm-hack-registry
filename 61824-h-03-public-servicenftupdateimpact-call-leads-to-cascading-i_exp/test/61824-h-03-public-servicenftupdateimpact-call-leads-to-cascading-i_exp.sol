// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61824-h-03-public-servicenftupdateimpact-call-leads-to-cascading-i.sol";
contract Virtuals61824Test is Test { function test_publicUpdateRewritesImpactAndRewards() public { Exploit e = new Exploit(); e.run(); assertEq(e.baselineImpact(), 20); assertEq(e.attackerImpact(), 90); assertEq(e.reward().balanceOf(address(e)), 90); } }
