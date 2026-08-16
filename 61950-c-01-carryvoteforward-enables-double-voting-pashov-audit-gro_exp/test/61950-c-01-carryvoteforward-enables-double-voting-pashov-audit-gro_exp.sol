// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import {Exploit, Voter, VotingEscrow, MiniToken} from "./61950-c-01-carryvoteforward-enables-double-voting-pashov-audit-gro.sol";
contract Finding61950Test is Test {
    function test_carryVoteForward_doubleVoting() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.gaugeVotesAfter(), 200 ether, "gauge counted 2W");
        assertEq(e.doubleCounted(), 100 ether, "W double-counted");
    }
}
