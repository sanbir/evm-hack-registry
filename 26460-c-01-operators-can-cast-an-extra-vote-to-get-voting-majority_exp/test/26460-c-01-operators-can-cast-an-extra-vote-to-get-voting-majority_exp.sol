// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MockToken, PoolGovernanceFixed, Receiver} from "./26460-c-01-operators-can-cast-an-extra-vote-to-get-voting-majority.sol";

contract Finding26460Test is Test {
    bytes32 internal constant CHOICE = keccak256("epoch");

    function test_exploit_second_vote_counts_as_two_and_pays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.gov().lastCount(), 2, "counted power is 2");
        assertEq(e.gov().voteCounter(0, CHOICE), 1, "stake is 1");
        assertTrue(e.gov().executed(), "proposal flipped");
        assertEq(e.token().balanceOf(e.sink()), 1_000 ether, "1000 paid");
    }

    function test_control_repeat_vote_counts_once() public {
        MockToken token = new MockToken();
        Receiver sink = new Receiver();
        PoolGovernanceFixed gov = new PoolGovernanceFixed(address(token), address(sink));
        token.mint(address(gov), 1_000 ether);
        gov.addOperator(address(this));
        gov.addOperator(address(new Receiver()));
        gov.addOperator(address(new Receiver()));

        gov.proposeEpoch(CHOICE);
        gov.proposeEpoch(CHOICE);

        assertEq(gov.lastCount(), 1, "counted once");
        assertEq(gov.voteCounter(0, CHOICE), 1, "counter is 1");
        assertFalse(gov.executed(), "not executed");
        assertEq(token.balanceOf(address(sink)), 0, "nothing paid");
        assertEq(token.balanceOf(address(gov)), 1_000 ether, "treasury kept");
    }
}
