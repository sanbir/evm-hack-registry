// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Reward, VePegFixed} from
    "./57821-c-01-delegate-permits-unauthorized-vote-delegation-pashov-au.sol";

contract Finding57821Test is Test {
    function test_exploit_steals_1000_votes_and_emissions() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.reward().balanceOf(address(e)), 1_000 ether, "attacker paid 1000");
        assertEq(e.peg().votes(e.VICTIM()), 0, "victim has no votes");
        assertEq(e.peg().ownerOf(1), e.VICTIM(), "nft still the victim");
        assertEq(e.stolenVotes(), 1_000 ether, "weight moved");
    }

    function test_control_stranger_cannot_delegate() public {
        Reward reward = new Reward();
        VePegFixed fixedPeg = new VePegFixed(reward);
        address victim = address(uint160(uint256(keccak256("victim"))));
        fixedPeg.mintLock(victim, 1, 1_000 ether);
        fixedPeg.mintLock(address(this), 2, 0);
        vm.expectRevert(bytes("not owner"));
        fixedPeg.delegate(1, 2);
        assertEq(fixedPeg.votes(victim), 1_000 ether, "votes stay");
    }
}
