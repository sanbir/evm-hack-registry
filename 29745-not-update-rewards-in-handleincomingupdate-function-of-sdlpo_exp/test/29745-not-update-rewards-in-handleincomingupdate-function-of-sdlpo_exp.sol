// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol"; import "./29745-not-update-rewards-in-handleincomingupdate-function-of-sdlpo.sol";
contract StakeLinkRewardTest is Test {function test_unsettledBalanceBricksRewards() external {Exploit e=new Exploit();e.run();assertEq(e.pool().rewardPool(),1000);}}
