// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    ERC20GuildFixed
} from "./19343-voting-tally-does-not-count-the-zero-action-sigmaprime-none.sol";

contract Finding19343Test is Test {
    function test_exploit_zero_action_omitted_and_payout_flips() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.guild().omittedZeroVotes(), 29, "zero action votes");
        assertEq(e.guild().scannedVotes(), 30, "scanned total");
        assertEq(e.guild().scannedVotes() + 29, 59, "off by 29");
        assertEq(e.guild().winningVotes(), 30, "winning total");
        assertEq(50 - e.guild().winningVotes(), 20, "short of majority by 20");
        assertEq(e.guild().winningAction(), 1, "action 1 wins");
        assertEq(e.guild().paid(), 1_000 ether, "payout");
        assertEq(e.token().balanceOf(address(e.sink())), 1_000 ether, "sink received 1000");
    }

    function test_control_majority_bar_pays_nothing() public {
        MockToken token = new MockToken("Guild", "GUILD", 18);
        ERC20GuildFixed fixedGuild = new ERC20GuildFixed(address(token), address(this));
        token.mint(address(fixedGuild), 1_000 ether);

        vm.expectRevert(bytes("required assumption by endProposal default voting tally"));
        fixedGuild.setConfig(30);

        fixedGuild.setConfig(50);
        fixedGuild.seed(keccak256("proposal"), 29, 30);
        fixedGuild.endProposal(keccak256("proposal"));

        assertEq(fixedGuild.winningAction(), 0, "zero action wins");
        assertEq(fixedGuild.paid(), 0, "no payout");
        assertEq(token.balanceOf(address(fixedGuild)), 1_000 ether, "treasury kept");
        assertEq(token.balanceOf(address(this)), 0, "caller paid nothing");
    }
}
