// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GuildToken, BaseERC20Guild, EnforcedBinaryGuild} from "./19346-duplicate-actions-unaccounted-for-during-voting-tally-sigmap.sol";
contract Finding19346Test is Test {
    function test_split_no_votes_let_the_proposal_pass() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.drained(), 100e18);
        assertTrue(e.base().executed(e.proposalId()));
        assertEq(e.base().votesLength(e.proposalId()), 3);
        assertEq(e.token().balanceOf(address(e)), 100e18);
    }
    function test_control_single_no_slot_rejects() public {
        GuildToken token = new GuildToken();
        BaseERC20Guild base = new BaseERC20Guild(token);
        EnforcedBinaryGuild guild = new EnforcedBinaryGuild(base);
        token.mint(address(base), 100e18);
        bytes memory data = abi.encodeWithSignature("transfer(address,uint256)", address(this), uint256(100e18));
        uint256 id = guild.createProposalFixed(address(token), data);
        assertEq(base.votesLength(id), 2);
        base.vote(id, 0, 80e18);
        base.vote(id, 1, 50e18);
        vm.expectRevert("rejected");
        base.endProposal(id);
        assertEq(token.balanceOf(address(base)), 100e18);
    }
}
