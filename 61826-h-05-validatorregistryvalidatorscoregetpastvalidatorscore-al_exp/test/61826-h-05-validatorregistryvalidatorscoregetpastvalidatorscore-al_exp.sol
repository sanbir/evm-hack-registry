// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./61826-h-05-validatorregistryvalidatorscoregetpastvalidatorscore-al.sol";
contract Virtuals61826Test is Test { function test_newValidatorGetsFullRewardWithoutVoting() public { Exploit e=new Exploit(); e.run(); assertEq(e.activeScore(),1); assertEq(e.freeRiderScore(),2); assertEq(e.reward().balanceOf(e.NEW_VALIDATOR()),100); } }
