// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VotingEscrowFixed, MockToken} from "./58015-h-04-duplicate-tokenid-in-delegate-list-may-inflate-votes-pa.sol";

contract DuplicateVoteTest is Test {
    function test_exploit_powerIs2AndRewardIs200() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.power(), 2, "power");
        assertEq(e.paid(), 200 ether, "reward");
        assertEq(e.token().balanceOf(address(e)), 200 ether, "balance");
        assertEq(e.escrow().tokenAt(address(e), 0), 7, "id0");
        assertEq(e.escrow().tokenAt(address(e), 1), 7, "id1");
    }

    function test_control_rejectsTheDuplicateAndPays100() public {
        MockToken token = new MockToken();
        VotingEscrowFixed escrow = new VotingEscrowFixed(address(token));
        token.mint(address(escrow), 200 ether);

        escrow.moveToken(address(this), 7);
        vm.expectRevert(bytes("duplicate checkpoint"));
        escrow.moveToken(address(this), 7);

        assertEq(escrow.listLength(address(this)), 1, "power stays 1");
        uint256 paid = escrow.claim(address(this));
        assertEq(paid, 100 ether, "fair reward");
        assertEq(token.balanceOf(address(this)), 100 ether, "no extra vote paid");
    }
}
